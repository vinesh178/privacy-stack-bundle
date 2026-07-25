package catalog

import (
	"errors"
	"fmt"
	"os"
	"regexp"
	"slices"
	"strings"

	"gopkg.in/yaml.v3"
)

const APIVersion = "install.run/v1"

var applicationIDPattern = regexp.MustCompile(`^[a-z0-9]+(?:-[a-z0-9]+)*$`)

type Application struct {
	APIVersion    string               `yaml:"apiVersion" json:"apiVersion"`
	Kind          string               `yaml:"kind" json:"kind"`
	Metadata      Metadata             `yaml:"metadata" json:"metadata"`
	Release       Release              `yaml:"release" json:"release"`
	Deployment    Deployment           `yaml:"deployment" json:"deployment"`
	Configuration []ConfigurationField `yaml:"configuration" json:"configuration"`
}

type Metadata struct {
	ID          string `yaml:"id" json:"id"`
	Name        string `yaml:"name" json:"name"`
	Description string `yaml:"description" json:"description"`
}

type Release struct {
	Version string `yaml:"version" json:"version"`
}

type Deployment struct {
	Compose        string  `yaml:"compose" json:"compose"`
	PrimaryService string  `yaml:"primaryService" json:"primaryService"`
	SetupScript    string  `yaml:"setupScript" json:"setupScript,omitempty"`
	Ingress        Ingress `yaml:"ingress" json:"ingress"`
}

type Ingress struct {
	Service string `yaml:"service" json:"service"`
	Port    int    `yaml:"port" json:"port"`
}

type ConfigurationField struct {
	Key      string `yaml:"key" json:"key"`
	Type     string `yaml:"type" json:"type"`
	Required bool   `yaml:"required" json:"required"`
	Default  string `yaml:"default" json:"default,omitempty"`
	Env      string `yaml:"env" json:"env,omitempty"`
}

func LoadManifest(path string) (Application, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Application{}, fmt.Errorf("read manifest: %w", err)
	}

	var app Application
	decoder := yaml.NewDecoder(strings.NewReader(string(data)))
	decoder.KnownFields(true)
	if err := decoder.Decode(&app); err != nil {
		return Application{}, fmt.Errorf("decode manifest: %w", err)
	}
	if err := app.Validate(); err != nil {
		return Application{}, err
	}
	return app, nil
}

func (app Application) Validate() error {
	var problems []string
	if app.APIVersion != APIVersion {
		problems = append(problems, `apiVersion must be "install.run/v1"`)
	}
	if app.Kind != "Application" {
		problems = append(problems, `kind must be "Application"`)
	}
	if !applicationIDPattern.MatchString(app.Metadata.ID) {
		problems = append(problems, "metadata.id must contain only lowercase letters, numbers, and single hyphens")
	}
	if strings.TrimSpace(app.Metadata.Name) == "" {
		problems = append(problems, "metadata.name is required")
	}
	if strings.TrimSpace(app.Release.Version) == "" {
		problems = append(problems, "release.version is required")
	}
	if strings.TrimSpace(app.Deployment.Compose) == "" {
		problems = append(problems, "deployment.compose is required")
	}
	if strings.TrimSpace(app.Deployment.PrimaryService) == "" {
		problems = append(problems, "deployment.primaryService is required")
	}
	if app.Deployment.Ingress.Port < 0 || app.Deployment.Ingress.Port > 65535 {
		problems = append(problems, "deployment.ingress.port must be 0 (disabled) or between 1 and 65535")
	}

	seenKeys := make(map[string]struct{}, len(app.Configuration))
	allowedTypes := []string{"boolean", "hostname", "integer", "secret", "string"}
	for index, field := range app.Configuration {
		if strings.TrimSpace(field.Key) == "" {
			problems = append(problems, fmt.Sprintf("configuration[%d].key is required", index))
		}
		if !slices.Contains(allowedTypes, field.Type) {
			problems = append(problems, fmt.Sprintf("configuration[%d].type must be one of %s", index, strings.Join(allowedTypes, ", ")))
		}
		if _, exists := seenKeys[field.Key]; exists {
			problems = append(problems, fmt.Sprintf("configuration key %q is duplicated", field.Key))
		}
		seenKeys[field.Key] = struct{}{}
	}

	if len(problems) > 0 {
		return errors.New(strings.Join(problems, "\n"))
	}
	return nil
}
