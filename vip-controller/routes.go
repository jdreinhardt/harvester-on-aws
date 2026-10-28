package main

import (
	"context"
	"errors"
	"fmt"
	"net/netip"
	"sort"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
)

// The ConfigMap listing the VPC routes that follow the VIP. Optional: when it
// does not exist, no route table is touched.
//
// Each key is a route table ID; each value lists the destination CIDRs in that
// table, separated by whitespace or commas. Only listed routes are changed,
// and they must already exist: like aws-vpc-move-ip, this replaces a route's
// target but never creates or deletes a route.
const routesConfigMap = "vip-controller-routes"

// routeSet maps a route table ID to the destination CIDRs to keep on this
// node's ENI.
type routeSet map[string][]string

func parseRoutes(data map[string]string) (routeSet, error) {
	rs := routeSet{}
	for rtb, v := range data {
		if !strings.HasPrefix(rtb, "rtb-") {
			return nil, fmt.Errorf("key %q is not a route table ID", rtb)
		}
		for _, f := range strings.FieldsFunc(v, func(r rune) bool { return r == ',' || r == ' ' || r == '\t' || r == '\n' }) {
			p, err := netip.ParsePrefix(f)
			if err != nil || !p.Addr().Is4() {
				return nil, fmt.Errorf("%s: %q is not an IPv4 CIDR", rtb, f)
			}
			// EC2 stores routes in canonical form; 10.60.0.1/24 would never match.
			if p != p.Masked() {
				return nil, fmt.Errorf("%s: %q has host bits set; use %s", rtb, f, p.Masked())
			}
			rs[rtb] = append(rs[rtb], f)
		}
	}
	return rs, nil
}

// routeChange records one route moved onto this node's ENI.
type routeChange struct {
	table, cidr, from string
}

// ensureRoutes points every listed route at this node's ENI. One table or
// route failing does not stop the others; all errors are returned together.
func (c *claimer) ensureRoutes(ctx context.Context, rs routeSet) ([]routeChange, error) {
	var (
		changes []routeChange
		errs    []error
	)
	tables := make([]string, 0, len(rs))
	for t := range rs {
		tables = append(tables, t)
	}
	sort.Strings(tables)

	for _, table := range tables {
		out, err := c.ec2.DescribeRouteTables(ctx, &ec2.DescribeRouteTablesInput{RouteTableIds: []string{table}})
		if err != nil {
			errs = append(errs, fmt.Errorf("describe %s: %w", table, err))
			continue
		}
		if len(out.RouteTables) != 1 {
			errs = append(errs, fmt.Errorf("describe %s: %d tables returned", table, len(out.RouteTables)))
			continue
		}
		// Destination -> current target ENI.
		targets := map[string]string{}
		for _, r := range out.RouteTables[0].Routes {
			if r.DestinationCidrBlock != nil {
				targets[*r.DestinationCidrBlock] = aws.ToString(r.NetworkInterfaceId)
			}
		}
		for _, cidr := range rs[table] {
			from, ok := targets[cidr]
			switch {
			case !ok:
				errs = append(errs, fmt.Errorf("%s has no route for %s; create it first", table, cidr))
			case from == c.eni:
			default:
				_, err := c.ec2.ReplaceRoute(ctx, &ec2.ReplaceRouteInput{
					RouteTableId:         aws.String(table),
					DestinationCidrBlock: aws.String(cidr),
					NetworkInterfaceId:   aws.String(c.eni),
				})
				if err != nil {
					errs = append(errs, fmt.Errorf("replace %s in %s: %w", cidr, table, err))
					continue
				}
				changes = append(changes, routeChange{table: table, cidr: cidr, from: from})
			}
		}
	}
	return changes, errors.Join(errs...)
}
