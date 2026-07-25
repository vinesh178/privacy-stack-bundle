package planner_test

import (
	"reflect"
	"testing"

	"github.com/vinesh178/privacy-stack-bundle/internal/catalog"
	"github.com/vinesh178/privacy-stack-bundle/internal/planner"
)

func TestBuildInstallPlanProducesDeterministicIsolatedOperations(t *testing.T) {
	app := catalog.Application{
		APIVersion: "install.run/v1",
		Kind:       "Application",
		Metadata: catalog.Metadata{
			ID:   "immich",
			Name: "Immich",
		},
		Release: catalog.Release{Version: "1.133.0"},
		Deployment: catalog.Deployment{
			Compose:        "compose.yaml",
			PrimaryService: "server",
			SetupScript:    "scripts/setup.sh",
			Ingress: catalog.Ingress{
				Service: "server",
				Port:    2283,
			},
		},
		Configuration: []catalog.ConfigurationField{
			{Key: "domain", Type: "hostname", Required: false},
			{Key: "adminPassword", Type: "secret", Required: true},
		},
	}

	input := planner.InstallRequest{
		Instance: "family-photos",
		Values: map[string]string{
			"domain":        "photos.example.com",
			"adminPassword": "do-not-leak",
		},
	}

	first, err := planner.BuildInstallPlan(app, input)
	if err != nil {
		t.Fatalf("BuildInstallPlan() error = %v", err)
	}
	second, err := planner.BuildInstallPlan(app, input)
	if err != nil {
		t.Fatalf("BuildInstallPlan() second error = %v", err)
	}

	if !reflect.DeepEqual(first, second) {
		t.Fatalf("plans differ:\nfirst: %#v\nsecond: %#v", first, second)
	}
	if first.InstanceID != "immich-family-photos" {
		t.Fatalf("InstanceID = %q, want immich-family-photos", first.InstanceID)
	}
	wantOperations := []planner.Operation{
		{Type: planner.ValidateHost, Target: "Ubuntu 22.04/24.04 LTS"},
		{Type: planner.RunCuratedSetup, Target: "scripts/setup.sh"},
		{Type: planner.VerifyHealth, Target: "server"},
		{Type: planner.RecordInstallation, Target: "immich-family-photos"},
	}
	if !reflect.DeepEqual(first.Operations, wantOperations) {
		t.Fatalf("Operations = %#v, want %#v", first.Operations, wantOperations)
	}
	if _, exists := first.Configuration["adminPassword"]; exists {
		t.Fatal("secret value was included in the plan")
	}
	if got := first.SecretReferences["adminPassword"]; got != "generated-or-provided:adminPassword" {
		t.Fatalf("secret reference = %q", got)
	}
}

func TestBuildInstallPlanRejectsMissingRequiredConfiguration(t *testing.T) {
	app := catalog.Application{
		APIVersion: "install.run/v1",
		Kind:       "Application",
		Metadata:   catalog.Metadata{ID: "vaultwarden", Name: "Vaultwarden"},
		Release:    catalog.Release{Version: "1.0.0"},
		Deployment: catalog.Deployment{
			Compose:        "compose.yaml",
			PrimaryService: "server",
			SetupScript:    "scripts/setup.sh",
		},
		Configuration: []catalog.ConfigurationField{
			{Key: "domain", Type: "hostname", Required: true},
		},
	}

	_, err := planner.BuildInstallPlan(app, planner.InstallRequest{Instance: "main"})
	if err == nil || err.Error() != `required configuration "domain" is missing` {
		t.Fatalf("error = %v, want missing domain error", err)
	}
}
