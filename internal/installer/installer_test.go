package installer_test

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/vinesh178/privacy-stack-bundle/internal/catalog"
	"github.com/vinesh178/privacy-stack-bundle/internal/installer"
	"github.com/vinesh178/privacy-stack-bundle/internal/planner"
)

type recordingRunner struct {
	name        string
	args        []string
	environment map[string]string
}

func (runner *recordingRunner) Run(_ context.Context, environment map[string]string, name string, args ...string) error {
	runner.name = name
	runner.args = append([]string(nil), args...)
	runner.environment = environment
	return nil
}

func TestInstallRunsCuratedSetupAndWritesReceipt(t *testing.T) {
	root := t.TempDir()
	script := filepath.Join(root, "scripts", "setup.sh")
	if err := os.MkdirAll(filepath.Dir(script), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(script, []byte("#!/usr/bin/env bash\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	stateDir := filepath.Join(t.TempDir(), "state")
	runner := &recordingRunner{}
	service := installer.Service{
		RepositoryRoot: root,
		StateDir:       stateDir,
		Runner:         runner,
	}
	app := catalog.Application{
		Metadata:   catalog.Metadata{ID: "privacy-stack", Name: "Privacy Stack"},
		Release:    catalog.Release{Version: "0.1.0"},
		Deployment: catalog.Deployment{SetupScript: "scripts/setup.sh"},
		Configuration: []catalog.ConfigurationField{
			{Key: "domain", Type: "hostname", Env: "DOMAIN"},
		},
	}
	plan := planner.Plan{
		Application: "privacy-stack",
		Version:     "0.1.0",
		InstanceID:  "privacy-stack-default",
		Configuration: map[string]string{
			"domain": "home.example.com",
		},
	}

	receipt, err := service.Install(context.Background(), app, plan, true)
	if err != nil {
		t.Fatalf("Install() error = %v", err)
	}
	if runner.name != "bash" {
		t.Fatalf("runner command = %q, want bash", runner.name)
	}
	if len(runner.args) != 2 || runner.args[0] != script || runner.args[1] != "--non-interactive" {
		t.Fatalf("runner args = %#v", runner.args)
	}
	if runner.environment["DOMAIN"] != "home.example.com" {
		t.Fatalf("runner environment = %#v", runner.environment)
	}
	if receipt.Status != "installed" {
		t.Fatalf("receipt status = %q", receipt.Status)
	}

	data, err := os.ReadFile(filepath.Join(stateDir, "privacy-stack-default.json"))
	if err != nil {
		t.Fatalf("read receipt: %v", err)
	}
	var stored installer.Receipt
	if err := json.Unmarshal(data, &stored); err != nil {
		t.Fatalf("decode receipt: %v", err)
	}
	if stored.Application != "privacy-stack" || stored.Version != "0.1.0" {
		t.Fatalf("stored receipt = %#v", stored)
	}

	receipts, err := installer.ListReceipts(stateDir)
	if err != nil {
		t.Fatalf("ListReceipts() error = %v", err)
	}
	if len(receipts) != 1 || receipts[0].InstanceID != "privacy-stack-default" {
		t.Fatalf("receipts = %#v", receipts)
	}
}

func TestInstallRejectsSetupScriptOutsideRepository(t *testing.T) {
	service := installer.Service{
		RepositoryRoot: t.TempDir(),
		StateDir:       t.TempDir(),
		Runner:         &recordingRunner{},
	}
	app := catalog.Application{
		Deployment: catalog.Deployment{SetupScript: "../unsafe.sh"},
	}

	_, err := service.Install(context.Background(), app, planner.Plan{}, true)
	if err == nil || err.Error() != "setup script must stay within the repository" {
		t.Fatalf("error = %v", err)
	}
}
