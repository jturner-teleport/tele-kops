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
					if !slices.Equal(roles, []string{"role-ssh-access"}) {
						log.Printf("SKIP request %s from %s for roles %v — not sole ssh-access request",
							req.GetName(), req.GetUser(), roles)
						continue
					}

					log.Printf("AUTO-APPROVING request %s from %s for role-ssh-access", req.GetName(), req.GetUser())
					if err := clt.SetAccessRequestState(ctx, types.AccessRequestUpdate{
						RequestID: req.GetName(),
						State:     types.RequestState_APPROVED,
						Reason:    "auto-approved: role-ssh-access is a low-risk role",
					}); err != nil {
						log.Printf("ERROR approving request %s: %v", req.GetName(), err)
					}

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
