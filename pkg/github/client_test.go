package github

import (
	"context"
	"testing"

	gogithub "github.com/google/go-github/v84/github"
)

func TestGetPRInfo_InvalidRepoFormat(t *testing.T) {
	client := &Client{client: gogithub.NewClient(nil)}
	ctx := context.Background()

	tests := []struct {
		name string
		repo string
	}{
		{name: "no slash", repo: "no-slash"},
		{name: "empty string", repo: ""},
		{name: "too many slashes", repo: "a/b/c"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := client.GetPRInfo(ctx, tt.repo, 1)
			if err == nil {
				t.Error("expected error for invalid repo format")
			}
		})
	}
}

func TestGetPRInfoFromEnv_MissingEnvVars(t *testing.T) {
	client := &Client{client: gogithub.NewClient(nil)}
	ctx := context.Background()

	tests := []struct {
		env  map[string]string
		name string
	}{
		{
			name: "all missing",
			env:  map[string]string{},
		},
		{
			name: "missing REPO_NAME and PULL_NUMBER",
			env:  map[string]string{"REPO_OWNER": "owner"},
		},
		{
			name: "missing PULL_NUMBER",
			env: map[string]string{
				"REPO_OWNER": "owner",
				"REPO_NAME":  "repo",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Clear env vars
			for _, key := range []string{"REPO_OWNER", "REPO_NAME", "PULL_NUMBER"} {
				t.Setenv(key, "")
			}
			// Set test env vars
			for k, v := range tt.env {
				t.Setenv(k, v)
			}

			_, _, err := client.GetPRInfoFromEnv(ctx)
			if err == nil {
				t.Error("expected error for missing env vars")
			}
		})
	}
}

func TestGetPRInfoFromEnv_InvalidPullNumber(t *testing.T) {
	client := &Client{client: gogithub.NewClient(nil)}
	ctx := context.Background()

	t.Setenv("REPO_OWNER", "owner")
	t.Setenv("REPO_NAME", "repo")
	t.Setenv("PULL_NUMBER", "not-a-number")

	_, _, err := client.GetPRInfoFromEnv(ctx)
	if err == nil {
		t.Error("expected error for invalid PULL_NUMBER")
	}
}
