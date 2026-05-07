module github.com/jturner-teleport/kops-teleport-dev-cluster/bot

go 1.22

// Teleport API version must match the cluster version (TELEPORT_VERSION=18 → teleport/api v18.x).
// Run: go get github.com/gravitational/teleport/api@latest to pin the correct version,
// then commit the updated go.mod and go.sum.
// go.sum is not committed here — run `go mod tidy` after pinning the version.
require (
	github.com/gravitational/teleport/api v18.0.0
)
