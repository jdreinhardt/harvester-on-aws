package main

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/ec2/types"
	coordinationv1 "k8s.io/api/coordination/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

type fakeEC2 struct {
	holders   []string // ENIs DescribeNetworkInterfaces reports
	assigned  *ec2.AssignPrivateIpAddressesInput
	assignErr error
}

func (f *fakeEC2) DescribeNetworkInterfaces(_ context.Context, _ *ec2.DescribeNetworkInterfacesInput, _ ...func(*ec2.Options)) (*ec2.DescribeNetworkInterfacesOutput, error) {
	out := &ec2.DescribeNetworkInterfacesOutput{}
	for _, id := range f.holders {
		out.NetworkInterfaces = append(out.NetworkInterfaces, types.NetworkInterface{NetworkInterfaceId: aws.String(id)})
	}
	return out, nil
}

func (f *fakeEC2) AssignPrivateIpAddresses(_ context.Context, in *ec2.AssignPrivateIpAddressesInput, _ ...func(*ec2.Options)) (*ec2.AssignPrivateIpAddressesOutput, error) {
	f.assigned = in
	return &ec2.AssignPrivateIpAddressesOutput{}, f.assignErr
}

// Route calls are faked in routes_test.go; the VIP tests never make them.
func (f *fakeEC2) DescribeRouteTables(context.Context, *ec2.DescribeRouteTablesInput, ...func(*ec2.Options)) (*ec2.DescribeRouteTablesOutput, error) {
	return nil, errors.New("unexpected DescribeRouteTables")
}

func (f *fakeEC2) ReplaceRoute(context.Context, *ec2.ReplaceRouteInput, ...func(*ec2.Options)) (*ec2.ReplaceRouteOutput, error) {
	return nil, errors.New("unexpected ReplaceRoute")
}

func TestEnsure(t *testing.T) {
	tests := []struct {
		name      string
		holders   []string
		assignErr error
		wantOwner string
		wantMoved bool
		wantErr   bool
	}{
		{name: "already ours", holders: []string{"eni-self"}, wantOwner: "eni-self"},
		{name: "on another node", holders: []string{"eni-other"}, wantOwner: "eni-other", wantMoved: true},
		{name: "unassigned", wantMoved: true},
		{name: "assign fails", holders: []string{"eni-other"}, assignErr: errors.New("denied"), wantOwner: "eni-other", wantErr: true},
		{name: "ambiguous", holders: []string{"eni-a", "eni-b"}, wantErr: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			f := &fakeEC2{holders: tt.holders, assignErr: tt.assignErr}
			c := &claimer{ec2: f, vip: "10.0.0.10", eni: "eni-self", vpc: "vpc-1"}
			owner, moved, err := c.ensure(context.Background())
			if (err != nil) != tt.wantErr || owner != tt.wantOwner || moved != tt.wantMoved {
				t.Fatalf("got owner=%q moved=%v err=%v", owner, moved, err)
			}
			if tt.wantMoved {
				in := f.assigned
				if aws.ToString(in.NetworkInterfaceId) != "eni-self" || !aws.ToBool(in.AllowReassignment) ||
					len(in.PrivateIpAddresses) != 1 || in.PrivateIpAddresses[0] != "10.0.0.10" {
					t.Fatalf("unexpected assign call: %+v", in)
				}
			}
		})
	}
}

func TestHeldBy(t *testing.T) {
	now := time.Now()
	lease := func(holder string, renewed time.Duration, seconds int32) *coordinationv1.Lease {
		l := &coordinationv1.Lease{}
		if holder != "" {
			l.Spec.HolderIdentity = &holder
		}
		r := metav1.NewMicroTime(now.Add(-renewed))
		l.Spec.RenewTime = &r
		l.Spec.LeaseDurationSeconds = &seconds
		return l
	}
	tests := []struct {
		name string
		l    *coordinationv1.Lease
		want bool
	}{
		{"held and fresh", lease("node-a", time.Second, 5), true},
		{"other holder", lease("node-b", time.Second, 5), false},
		{"expired", lease("node-a", 10*time.Second, 5), false},
		{"no holder", lease("", time.Second, 5), false},
		{"no renew time", &coordinationv1.Lease{Spec: coordinationv1.LeaseSpec{HolderIdentity: aws.String("node-a")}}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := heldBy(tt.l, "node-a", now); got != tt.want {
				t.Fatalf("heldBy = %v, want %v", got, tt.want)
			}
		})
	}
}
