package catalog_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/vinesh178/privacy-stack-bundle/internal/catalog"
)

func TestLoadManifestReturnsValidatedApplication(t *testing.T) {
	path := writeManifest(t, `
apiVersion: install.run/v1
kind: Application
metadata:
  id: immich
  name: Immich
release:
  version: 1.133.0
deployment:
  compose: compose.yaml
  primaryService: server
  ingress:
    service: server
    port: 2283
configuration:
  - key: domain
    type: hostname
    required: false
`)

	app, err := catalog.LoadManifest(path)
	if err != nil {
		t.Fatalf("LoadManifest() error = %v", err)
	}

	if app.Metadata.ID != "immich" {
		t.Fatalf("Metadata.ID = %q, want immich", app.Metadata.ID)
	}
	if app.Deployment.Ingress.Port != 2283 {
		t.Fatalf("Ingress.Port = %d, want 2283", app.Deployment.Ingress.Port)
	}
}

func TestLoadManifestReportsAllActionableValidationErrors(t *testing.T) {
	path := writeManifest(t, `
apiVersion: install.run/v2
kind: Widget
metadata:
  id: Bad ID
deployment:
  ingress:
    port: 70000
configuration:
  - key: token
    type: mystery
  - key: token
    type: secret
`)

	_, err := catalog.LoadManifest(path)
	if err == nil {
		t.Fatal("LoadManifest() error = nil, want validation error")
	}

	for _, want := range []string{
		`apiVersion must be "install.run/v1"`,
		`kind must be "Application"`,
		`metadata.id must contain only lowercase letters`,
		`metadata.name is required`,
		`release.version is required`,
		`deployment.compose is required`,
		`deployment.primaryService is required`,
		`deployment.ingress.port must be 0 (disabled) or between 1 and 65535`,
		`configuration[0].type must be one of`,
		`configuration key "token" is duplicated`,
	} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q does not contain %q", err, want)
		}
	}
}

func writeManifest(t *testing.T, contents string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "app.yaml")
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}
