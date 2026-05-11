package main

import (
	"context"
	"log"
	"os"
	"slices"
	"time"

	"github.com/gravitational/teleport/api/client"
	"github.com/gravitational/teleport/api/types"
)

func main() {
	ctx := context.Background()

	proxyAddr := os.Getenv("TELEPORT_PROXY_ADDR")
	if proxyAddr == "" {
		log.Fatal("TELEPORT_PROXY_ADDR not set")
	}
	identityFile := os.Getenv("TELEPORT_IDENTITY_FILE")
	if identityFile == "" {
		identityFile = "/var/run/secrets/teleport/identity"
	}

	clt, err := client.New(ctx, client.Config{
		Addrs: []string{proxyAddr},
		Credentials: []client.Credentials{
			client.LoadIdentityFile(identityFile),
		},
	})
	if err != nil {
		log.Fatalf("failed to create Teleport client: %v", err)
	}
	defer clt.Close()

	log.Printf("Connected to Teleport at %s — watching for ssh-access requests", proxyAddr)

	for {
		watcher, err := clt.NewWatcher(ctx, types.Watch{
			Kinds: []types.WatchKind{
				{Kind: types.KindAccessRequest},
			},
		})
		if err != nil {
			log.Printf("failed to create watcher, retrying in 5s: %v", err)
			select {
			case <-ctx.Done():
				return
			case <-time.After(5 * time.Second):
			}
			continue
		}

		func() {
			defer watcher.Close()
			for {
				select {
				case event := <-watcher.Events():
					if event.Type != types.OpPut {
						continue
					}
					req, ok := event.Resource.(types.AccessRequest)
					if !ok {
						continue
					}
					if req.GetState() != types.RequestState_PENDING {
						continue
					}

					roles := req.GetRoles()
					// Only auto-approve if the request is ONLY for role-ssh-access.
					// Any request touching role-ssh-root-access requires manual approval.
					if slices.Equal(roles, []string{"role-ssh-access"}) {
						log.Printf("AUTO-APPROVING request %s from %s for role-ssh-access", req.GetName(), req.GetUser())
						if err := clt.SetAccessRequestState(ctx, types.AccessRequestUpdate{
							RequestID: req.GetName(),
							State:     types.RequestState_APPROVED,
							Reason:    "auto-approved: role-ssh-access is a low-risk role",
						}); err != nil {
							log.Printf("ERROR approving request %s: %v", req.GetName(), err)
						}
						continue
					}

					// Auto-approve role-kube-access if the requester is a member of any
					// Access List granting the role-kube-access-auto-approved marker role.
					if slices.Equal(roles, []string{"role-kube-access"}) {
						member, matchingList, err := isMemberOfAccessListGranting(ctx, clt, req.GetUser(), "role-kube-access-auto-approved")
						if err != nil {
							log.Printf("ERROR checking access list membership for request %s from %s: %v — skipping (fail-safe)",
								req.GetName(), req.GetUser(), err)
							continue
						}
						if member {
							log.Printf("AUTO-APPROVING request %s from %s for role-kube-access (member of access list %q)",
								req.GetName(), req.GetUser(), matchingList)
							if err := clt.SetAccessRequestState(ctx, types.AccessRequestUpdate{
								RequestID: req.GetName(),
								State:     types.RequestState_APPROVED,
								Reason:    "auto-approved: requester is a member of access list " + matchingList,
							}); err != nil {
								log.Printf("ERROR approving request %s: %v", req.GetName(), err)
							}
						} else {
							log.Printf("SKIP request %s from %s for role-kube-access — not a member of any qualifying access list",
								req.GetName(), req.GetUser())
						}
						continue
					}

					log.Printf("SKIP request %s from %s for roles %v — not sole ssh-access request",
						req.GetName(), req.GetUser(), roles)

				case <-watcher.Done():
					log.Printf("watcher closed, reconnecting...")
					return

				case <-ctx.Done():
					return
				}
			}
		}()

		if ctx.Err() != nil {
			return
		}
	}
}

// isMemberOfAccessListGranting returns (true, listName, nil) if the given user
// is an explicit member of any Access List that grants markerRole. If no
// qualifying list is found it returns (false, "", nil). Any API error causes
// (false, "", err) so the caller can fail-safe.
func isMemberOfAccessListGranting(ctx context.Context, clt *client.Client, user, markerRole string) (bool, string, error) {
	// GetAccessLists returns all lists in a single call — no pagination needed.
	lists, err := clt.AccessListClient().GetAccessLists(ctx)
	if err != nil {
		return false, "", err
	}

	for _, al := range lists {
		grants := al.GetGrants()
		if !slices.Contains(grants.Roles, markerRole) {
			continue
		}

		// This list grants the marker role — check membership with pagination.
		isMember, err := isUserMemberOfList(ctx, clt, al.GetName(), user)
		if err != nil {
			return false, "", err
		}
		if isMember {
			return true, al.GetName(), nil
		}
	}

	return false, "", nil
}

// isUserMemberOfList checks whether user is an explicit member of the named
// Access List, paging through all members as needed.
func isUserMemberOfList(ctx context.Context, clt *client.Client, listName, user string) (bool, error) {
	var pageToken string
	for {
		members, nextToken, err := clt.AccessListClient().ListAccessListMembers(ctx, listName, 0 /* default page size */, pageToken)
		if err != nil {
			return false, err
		}
		for _, m := range members {
			if m.Spec.Name == user {
				return true, nil
			}
		}
		if nextToken == "" {
			break
		}
		pageToken = nextToken
	}
	return false, nil
}
