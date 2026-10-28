// vip-controller makes AWS follow kube-vip's election.
//
// kube-vip elects a leader through a Lease and binds the VIP on that node, but
// the VPC ignores ARP: the address only reaches the node whose ENI it is
// registered on. This runs on every control-plane node and, when the Lease
// names its own node, moves the VIP onto its own ENI with a single
// AssignPrivateIpAddresses call (AllowReassignment takes it off the old ENI).
//
// A node only ever claims the VIP for itself, and never unassigns it.
//
// Optionally, VPC routes listed in a ConfigMap (routes.go) follow the VIP the
// same way, as aws-vpc-move-ip does for its route tables.
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/feature/ec2/imds"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	coordinationv1 "k8s.io/api/coordination/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

const (
	// kube-vip's services-mode lease in Harvester.
	leaseNamespace = "harvester-system"
	leaseName      = "plndr-svcs-lock"

	// How often the Lease is read. kube-vip renews it every few seconds, so
	// this bounds how long after an election the claim starts.
	pollInterval = 2 * time.Second

	// Minimum gap between two claims, so a flapping lease cannot hammer the
	// EC2 API.
	claimBackoff = 5 * time.Second
)

func main() {
	nodeName := mustEnv("NODE_NAME")
	vip := mustEnv("VIP")
	recheck := 10 * time.Second
	if v := os.Getenv("RECHECK_INTERVAL"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			log.Fatalf("RECHECK_INTERVAL: %v", err)
		}
		recheck = d
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	restCfg, err := rest.InClusterConfig()
	if err != nil {
		log.Fatalf("kubernetes config: %v", err)
	}
	kube, err := kubernetes.NewForConfig(restCfg)
	if err != nil {
		log.Fatalf("kubernetes client: %v", err)
	}

	awsCfg, err := config.LoadDefaultConfig(ctx, config.WithEC2IMDSRegion())
	if err != nil {
		log.Fatalf("aws config: %v", err)
	}
	self, err := lookupSelf(ctx, imds.NewFromConfig(awsCfg))
	if err != nil {
		log.Fatalf("instance metadata: %v", err)
	}
	c := &claimer{ec2: ec2.NewFromConfig(awsCfg), vip: vip, eni: self.eni, vpc: self.vpc}

	log.Printf("node=%s instance=%s eni=%s vpc=%s vip=%s lease=%s/%s recheck=%s",
		nodeName, self.instance, self.eni, self.vpc, vip, leaseNamespace, leaseName, recheck)

	run(ctx, kube, c, nodeName, recheck)
}

// run polls the Lease and, while this node holds it, makes sure EC2 agrees:
// immediately on becoming holder, then every recheck interval. The periodic
// check also repairs the case where kube-vip re-elects while the old holder
// is healthy, which no node failure would ever signal.
func run(ctx context.Context, kube kubernetes.Interface, c *claimer, nodeName string, recheck time.Duration) {
	var (
		wasHolder   bool
		lastChecked time.Time
		lastClaim   time.Time
	)
	tick := time.NewTicker(pollInterval)
	defer tick.Stop()

	for {
		lease, err := kube.CoordinationV1().Leases(leaseNamespace).Get(ctx, leaseName, metav1.GetOptions{})
		now := time.Now()
		switch {
		case err != nil:
			log.Printf("read lease: %v", err)
		case !heldBy(lease, nodeName, now):
			if wasHolder {
				log.Printf("lease no longer held by this node (holder=%s)", holderOf(lease))
			}
			wasHolder = false
		default:
			becameHolder := !wasHolder
			wasHolder = true
			if becameHolder {
				log.Printf("this node holds the lease")
			}
			if becameHolder || now.Sub(lastChecked) >= recheck {
				if now.Sub(lastClaim) < claimBackoff {
					break
				}
				owner, moved, err := c.ensure(ctx)
				switch {
				case err != nil:
					log.Printf("ensure vip: %v", err)
				case moved:
					lastClaim = now
					log.Printf("claimed vip %s onto %s (was on %s)", c.vip, c.eni, orNone(owner))
				}
				if err == nil {
					lastChecked = now
				}
				syncRoutes(ctx, kube, c)
			}
		}

		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}

// syncRoutes reads the routes ConfigMap and points its routes at this node.
// It is read on every check rather than once at startup, so edits take
// effect within one recheck interval without restarting anything. A missing
// ConfigMap means no routes, and is not logged.
func syncRoutes(ctx context.Context, kube kubernetes.Interface, c *claimer) {
	cm, err := kube.CoreV1().ConfigMaps(leaseNamespace).Get(ctx, routesConfigMap, metav1.GetOptions{})
	if apierrors.IsNotFound(err) {
		return
	}
	if err != nil {
		log.Printf("read %s: %v", routesConfigMap, err)
		return
	}
	rs, err := parseRoutes(cm.Data)
	if err != nil {
		log.Printf("%s: %v", routesConfigMap, err)
		return
	}
	changes, err := c.ensureRoutes(ctx, rs)
	for _, ch := range changes {
		log.Printf("routed %s in %s to %s (was %s)", ch.cidr, ch.table, c.eni, orNone(ch.from))
	}
	if err != nil {
		log.Printf("ensure routes: %v", err)
	}
}

// heldBy reports whether the Lease names this node and has not expired. An
// expired lease is not acted on: kube-vip is mid-election, and the next
// holder will claim.
func heldBy(l *coordinationv1.Lease, nodeName string, now time.Time) bool {
	s := l.Spec
	if s.HolderIdentity == nil || *s.HolderIdentity != nodeName {
		return false
	}
	if s.RenewTime == nil || s.LeaseDurationSeconds == nil {
		return false
	}
	expires := s.RenewTime.Add(time.Duration(*s.LeaseDurationSeconds) * time.Second)
	return now.Before(expires)
}

func holderOf(l *coordinationv1.Lease) string {
	if l.Spec.HolderIdentity == nil {
		return "none"
	}
	return *l.Spec.HolderIdentity
}

func orNone(s string) string {
	if s == "" {
		return "no interface"
	}
	return s
}

func mustEnv(k string) string {
	v := os.Getenv(k)
	if v == "" {
		fmt.Fprintf(os.Stderr, "%s must be set\n", k)
		os.Exit(2)
	}
	return v
}
