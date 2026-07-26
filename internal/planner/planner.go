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
	Preset   string
	Values   map[string]string
}

type Plan struct {
	Application      string            `json:"application"`
	Version          string            `json:"version"`
	InstanceID       string            `json:"instanceId"`
	MinimumRAMMB     int               `json:"minimumRAMMB,omitempty"`
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

	requestValues := make(map[string]string)
	minimumRAM := 0
	if request.Preset != "" {
		preset, exists := app.Presets[request.Preset]
		if !exists {
			return Plan{}, fmt.Errorf("preset %q is not available for %s", request.Preset, app.Metadata.ID)
		}
		for key, value := range preset.Values {
			requestValues[key] = value
		}
		minimumRAM = preset.MinimumRAM
	}
	for key, value := range request.Values {
		requestValues[key] = value
	}

	values := make(map[string]string, len(app.Configuration))
	secretReferences := make(map[string]string)
	for _, field := range app.Configuration {
		value := requestValues[field.Key]
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
		MinimumRAMMB:     minimumRAM,
		Configuration:    sortedMap(values),
		SecretReferences: sortedMap(secretReferences),
		Operations: []Operation{
			{Type: ValidateHost, Target: "Linux with systemd and apt, dnf, or yum"},
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
