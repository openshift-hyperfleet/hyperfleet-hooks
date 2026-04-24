package github

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/google/go-github/v84/github"
)

// Client wraps GitHub API client
type Client struct {
	client *github.Client
}

// NewClient creates a new GitHub client
// It will use GITHUB_TOKEN environment variable if available
func NewClient() *Client {
	var client *github.Client
	token := os.Getenv("GITHUB_TOKEN")

	if token != "" {
		client = github.NewClient(nil).WithAuthToken(token)
	} else {
		fmt.Fprintln(os.Stderr, "⚠️  GITHUB_TOKEN not set — using unauthenticated GitHub API (60 req/hr rate limit)")
		client = github.NewClient(nil)
	}

	return &Client{
		client: client,
	}
}

// GetPRTitle fetches the title of a pull request
// repo format: "owner/name" or "org/repo"
func (c *Client) GetPRTitle(ctx context.Context, repo string, prNumber int) (string, error) {
	parts := strings.Split(repo, "/")
	if len(parts) != 2 {
		return "", fmt.Errorf("invalid repo format: %s (expected owner/repo)", repo)
	}

	owner := parts[0]
	repoName := parts[1]

	pr, _, err := c.client.PullRequests.Get(ctx, owner, repoName, prNumber)
	if err != nil {
		return "", fmt.Errorf("failed to fetch PR #%d: %w", prNumber, err)
	}

	if pr.Title == nil {
		return "", fmt.Errorf("PR #%d has no title", prNumber)
	}

	return *pr.Title, nil
}

// PRCommit holds a commit SHA and its message
type PRCommit struct {
	SHA     string
	Message string
}

// GetPRCommits fetches all commits for a pull request
func (c *Client) GetPRCommits(ctx context.Context, owner, repo string, prNumber int) ([]PRCommit, error) {
	var allCommits []PRCommit
	opts := &github.ListOptions{PerPage: 100}

	for {
		commits, resp, err := c.client.PullRequests.ListCommits(ctx, owner, repo, prNumber, opts)
		if err != nil {
			return nil, fmt.Errorf("failed to list commits for PR #%d: %w", prNumber, err)
		}

		for _, c := range commits {
			allCommits = append(allCommits, PRCommit{
				SHA:     c.GetSHA(),
				Message: c.GetCommit().GetMessage(),
			})
		}

		if resp.NextPage == 0 {
			break
		}
		opts.Page = resp.NextPage
	}

	return allCommits, nil
}

// GetPRCommitsFromEnv fetches PR commits using environment variables (REPO_OWNER, REPO_NAME, PULL_NUMBER)
func (c *Client) GetPRCommitsFromEnv(ctx context.Context) ([]PRCommit, error) {
	owner := os.Getenv("REPO_OWNER")
	repoName := os.Getenv("REPO_NAME")
	prNumberStr := os.Getenv("PULL_NUMBER")

	if owner == "" || repoName == "" || prNumberStr == "" {
		return nil, fmt.Errorf("missing required environment variables (REPO_OWNER, REPO_NAME, PULL_NUMBER)")
	}

	var prNumber int
	_, err := fmt.Sscanf(prNumberStr, "%d", &prNumber)
	if err != nil {
		return nil, fmt.Errorf("invalid PULL_NUMBER %q: %w", prNumberStr, err)
	}

	return c.GetPRCommits(ctx, owner, repoName, prNumber)
}

// GetPRTitleFromEnv fetches PR title using environment variables
// Uses REPO_OWNER, REPO_NAME, PULL_NUMBER from Prow
// Returns the PR title and the PR number string
func (c *Client) GetPRTitleFromEnv(ctx context.Context) (title string, prNumberStr string, err error) {
	owner := os.Getenv("REPO_OWNER")
	repoName := os.Getenv("REPO_NAME")
	prNumberStr = os.Getenv("PULL_NUMBER")

	if owner == "" || repoName == "" || prNumberStr == "" {
		return "", "", fmt.Errorf("missing required environment variables (REPO_OWNER, REPO_NAME, PULL_NUMBER)")
	}

	var prNumber int
	_, err = fmt.Sscanf(prNumberStr, "%d", &prNumber)
	if err != nil {
		return "", "", fmt.Errorf("invalid PULL_NUMBER %q: %w", prNumberStr, err)
	}

	repo := fmt.Sprintf("%s/%s", owner, repoName)
	title, err = c.GetPRTitle(ctx, repo, prNumber)
	if err != nil {
		return "", "", fmt.Errorf("fetching PR title from env: %w", err)
	}
	return title, prNumberStr, nil
}
