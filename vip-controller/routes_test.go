package main

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/ec2/types"
)

func TestParseRoutes(t *testing.T) {
	tests := []struct {
		name    string
		data    map[string]string
		want    map[string]int // table -> number of CIDRs
		wantErr bool
	}{
		{name: "empty", data: map[string]string{}, want: map[string]int{}},
		{name: "one per line", data: map[string]string{"rtb-1": "10.60.0.0/24\n10.61.0.0/24\n"}, want: map[string]int{"rtb-1": 2}},
		{name: "commas and spaces", data: map[string]string{"rtb-1": "10.60.0.0/24, 10.61.0.0/24", "rtb-2": "10.62.0.0/16"}, want: map[string]int{"rtb-1": 2, "rtb-2": 1}},
		{name: "table with no routes", data: map[string]string{"rtb-1": ""}, want: map[string]int{}},
		{name: "bad key", data: map[string]string{"routes": "10.60.0.0/24"}, wantErr: true},
		{name: "not a cidr", data: map[string]string{"rtb-1": "10.60.0.0"}, wantErr: true},
		{name: "host bits set", data: map[string]string{"rtb-1": "10.60.0.1/24"}, wantErr: true},
		{name: "ipv6", data: map[string]string{"rtb-1": "fd00::/64"}, wantErr: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rs, err := parseRoutes(tt.data)
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v", err)
			}
			if tt.wantErr {
				return
			}
			if len(rs) != len(tt.want) {
				t.Fatalf("got %v", rs)
			}
			for table, n := range tt.want {
				if len(rs[table]) != n {
					t.Fatalf("got %v", rs)
				}
			}
		})
	}
}

// routeEC2 fakes the route table calls; tables maps table -> destination -> ENI.
type routeEC2 struct {
	fakeEC2
	tables   map[string]map[string]string
	replaced []string
}

func (f *routeEC2) DescribeRouteTables(_ context.Context, in *ec2.DescribeRouteTablesInput, _ ...func(*ec2.Options)) (*ec2.DescribeRouteTablesOutput, error) {
	id := in.RouteTableIds[0]
	routes, ok := f.tables[id]
	if !ok {
		return nil, errors.New("InvalidRouteTableID.NotFound")
	}
	rt := types.RouteTable{RouteTableId: aws.String(id)}
	for dst, eni := range routes {
		r := types.Route{DestinationCidrBlock: aws.String(dst)}
		if eni != "" {
			r.NetworkInterfaceId = aws.String(eni)
		}
		rt.Routes = append(rt.Routes, r)
	}
	return &ec2.DescribeRouteTablesOutput{RouteTables: []types.RouteTable{rt}}, nil
}

func (f *routeEC2) ReplaceRoute(_ context.Context, in *ec2.ReplaceRouteInput, _ ...func(*ec2.Options)) (*ec2.ReplaceRouteOutput, error) {
	f.replaced = append(f.replaced, aws.ToString(in.RouteTableId)+" "+aws.ToString(in.DestinationCidrBlock)+" "+aws.ToString(in.NetworkInterfaceId))
	return &ec2.ReplaceRouteOutput{}, nil
}

func TestEnsureRoutes(t *testing.T) {
	f := &routeEC2{tables: map[string]map[string]string{
		"rtb-a": {
			"172.31.0.0/16": "",          // local route, not listed
			"10.60.0.0/24":  "eni-self",  // already ours
			"10.61.0.0/24":  "eni-other", // on the old holder, maybe blackholed
		},
		"rtb-b": {"10.60.0.0/24": "eni-other"},
	}}
	c := &claimer{ec2: f, vip: "10.0.0.10", eni: "eni-self", vpc: "vpc-1"}
	rs := routeSet{
		"rtb-a":       {"10.60.0.0/24", "10.61.0.0/24", "10.62.0.0/24"}, // last one missing
		"rtb-b":       {"10.60.0.0/24"},
		"rtb-missing": {"10.60.0.0/24"},
	}
	changes, err := c.ensureRoutes(context.Background(), rs)

	if len(changes) != 2 {
		t.Fatalf("changes = %+v", changes)
	}
	want := []string{"rtb-a 10.61.0.0/24 eni-self", "rtb-b 10.60.0.0/24 eni-self"}
	if strings.Join(f.replaced, ";") != strings.Join(want, ";") {
		t.Fatalf("replaced = %v, want %v", f.replaced, want)
	}
	// The missing route and missing table are reported, and did not stop the rest.
	if err == nil || !strings.Contains(err.Error(), "no route for 10.62.0.0/24") || !strings.Contains(err.Error(), "rtb-missing") {
		t.Fatalf("err = %v", err)
	}
}
