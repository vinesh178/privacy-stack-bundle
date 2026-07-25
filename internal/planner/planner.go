package planner

import (
	"fmt"
	"regexp"
	"sort"
	"strings"

	"github.com/vinesh178/privacy-stack-bundle/internal/catalog"
)

var instanceNamePattern = regexp.MustCompile(`^[a-z0-9]+(?:-[a-z0-9]+)*$`)

type InstallRequest struct {
	Instance string
	Values   map[string]string
}

type Plan struct {
	Application      string            `json:"application"`
	Version          string            `json:"version"`
	InstanceID       string            `json:"instanceId"`
	Configuration    map[string]string `json:"configuration,omitempty"`
	SecretReferences map[string]string `json:"secretReferences,omitempty"`
	Operations       []Operation       `json:"operations"`
}

type OperationType string

const (
	ValidateHost       OperationType = "validate_host"
	RunCuratedSetup    OperationType = "run_curated_setup"
	VerifyHealth       OperationType = "verify_health"
	RecordInstallation OperationType = "record_installation"
)

type Operation struct {
	Type   OperationType `json:"type"`
	Target string        `json:"target"`
}

func BuildInstallPlan(app catalog.Application, request InstallRequest) (Plan, error) {
	instance := request.Instance
	if instance == "" {
		instance = "default"
	}
	if !instanceNamePattern.MatchString(instance) {
		return Plan{}, fmt.Errorf("instance must contain only lowercase letters, numbers, and single hyphens")
	}

	values := make(map[string]string, len(app.Configuration))
	secretReferences := make(map[string]string)
	for _, field := range app.Configuration {
		value := request.Values[field.Key]
		if value == "" {
			value = field.Default
		}
		if field.Required && value == "" {
			return Plan{}, fmt.Errorf("required configuration %q is missing", field.Key)
		}
		if value == "" {
			continue
		}
		if field.Type == "secret" {
			secretReferences[field.Key] = "generated-or-provided:" + field.Key
			continue
		}
		values[field.Key] = value
	}

	instanceID := app.Metadata.ID + "-" + instance
	if app.Deployment.SetupScript == "" {
		return Plan{}, fmt.Errorf("application %q does not define a curated setup path", app.Metadata.ID)
	}

	return Plan{
		Application:      app.Metadata.ID,
		Version:          app.Release.Version,
		InstanceID:       instanceID,
		Configuration:    sortedMap(values),
		SecretReferences: sortedMap(secretReferences),
		Operations: []Operation{
			{Type: ValidateHost, Target: "Ubuntu 22.04/24.04 LTS"},
			{Type: RunCuratedSetup, Target: app.Deployment.SetupScript},
			{Type: VerifyHealth, Target: app.Deployment.PrimaryService},
			{Type: RecordInstallation, Target: instanceID},
		},
	}, nil
}

func sortedMap(input map[string]string) map[string]string {
	keys := make([]string, 0, len(input))
	for key := range input {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	output := make(map[string]string, len(input))
	for _, key := range keys {
		output[key] = strings.TrimSpace(input[key])
	}
	return output
}
