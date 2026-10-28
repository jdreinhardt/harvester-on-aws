package main

import (
	"context"
	"fmt"
	"io"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/feature/ec2/imds"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/ec2/types"
)

// ec2API is the part of the EC2 client the claimer uses, so tests can fake it.
type ec2API interface {
	DescribeNetworkInterfaces(context.Context, *ec2.DescribeNetworkInterfacesInput, ...func(*ec2.Options)) (*ec2.DescribeNetworkInterfacesOutput, error)
	AssignPrivateIpAddresses(context.Context, *ec2.AssignPrivateIpAddressesInput, ...func(*ec2.Options)) (*ec2.AssignPrivateIpAddressesOutput, error)
	DescribeRouteTables(context.Context, *ec2.DescribeRouteTablesInput, ...func(*ec2.Options)) (*ec2.DescribeRouteTablesOutput, error)
	ReplaceRoute(context.Context, *ec2.ReplaceRouteInput, ...func(*ec2.Options)) (*ec2.ReplaceRouteOutput, error)
}

// claimer keeps the VIP on this node's ENI.
type claimer struct {
	ec2 ec2API
	vip string
	eni string // this node's primary ENI, where mgmt-br lives
	vpc string // private addresses are only unique within a VPC
}

// ensure moves the VIP onto this node's ENI if it is anywhere else, including
// unassigned. It returns the ENI that held it before (empty if none) and
// whether it moved. EC2 is asked rather than instance metadata, which can lag
// behind an assignment.
func (c *claimer) ensure(ctx context.Context) (owner string, moved bool, err error) {
	owner, err = c.owner(ctx)
	if err != nil {
		return "", false, err
	}
	if owner == c.eni {
		return owner, false, nil
	}
	_, err = c.ec2.AssignPrivateIpAddresses(ctx, &ec2.AssignPrivateIpAddressesInput{
		NetworkInterfaceId: aws.String(c.eni),
		PrivateIpAddresses: []string{c.vip},
		AllowReassignment:  aws.Bool(true),
	})
	if err != nil {
		return owner, false, fmt.Errorf("assign %s to %s: %w", c.vip, c.eni, err)
	}
	return owner, true, nil
}

// owner returns the ENI in this VPC that currently has the VIP, or "".
func (c *claimer) owner(ctx context.Context) (string, error) {
	out, err := c.ec2.DescribeNetworkInterfaces(ctx, &ec2.DescribeNetworkInterfacesInput{
		Filters: []types.Filter{
			{Name: aws.String("vpc-id"), Values: []string{c.vpc}},
			{Name: aws.String("addresses.private-ip-address"), Values: []string{c.vip}},
		},
	})
	if err != nil {
		return "", fmt.Errorf("describe interfaces with %s: %w", c.vip, err)
	}
	switch len(out.NetworkInterfaces) {
	case 0:
		return "", nil
	case 1:
		return aws.ToString(out.NetworkInterfaces[0].NetworkInterfaceId), nil
	default:
		return "", fmt.Errorf("%d interfaces in %s report %s", len(out.NetworkInterfaces), c.vpc, c.vip)
	}
}

type self struct {
	instance, eni, vpc string
}

// lookupSelf reads this instance's identity from instance metadata. `mac` is
// the primary interface's address, which is the one mgmt-br bridges.
func lookupSelf(ctx context.Context, md *imds.Client) (self, error) {
	get := func(path string) (string, error) {
		out, err := md.GetMetadata(ctx, &imds.GetMetadataInput{Path: path})
		if err != nil {
			return "", fmt.Errorf("%s: %w", path, err)
		}
		defer out.Content.Close()
		b, err := io.ReadAll(out.Content)
		if err != nil {
			return "", fmt.Errorf("%s: %w", path, err)
		}
		return strings.TrimSpace(string(b)), nil
	}

	var s self
	var err error
	if s.instance, err = get("instance-id"); err != nil {
		return s, err
	}
	mac, err := get("mac")
	if err != nil {
		return s, err
	}
	if s.eni, err = get("network/interfaces/macs/" + mac + "/interface-id"); err != nil {
		return s, err
	}
	if s.vpc, err = get("network/interfaces/macs/" + mac + "/vpc-id"); err != nil {
		return s, err
	}
	return s, nil
}
