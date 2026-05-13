package commitlint

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
)

// Validator validates commit messages against HyperFleet standards
type Validator struct {
	commitPattern      *regexp.Regexp
	jiraPattern        *regexp.Regexp
	validTypes         map[string]bool
	maxSubjectLength   int
	whitelistedAuthors map[string]bool
}

// ValidationError represents a validation error
type ValidationError struct {
	Rule    string
	Message string
}

func (e *ValidationError) Error() string {
	return fmt.Sprintf("%s [%s]", e.Message, e.Rule)
}

// ValidationResult contains the result of validation
type ValidationResult struct {
	Errors []*ValidationError
	Valid  bool
}

// NewValidator creates a new commit message validator
func NewValidator() *Validator {
	return &Validator{
		validTypes: map[string]bool{
			"feat":     true,
			"fix":      true,
			"docs":     true,
			"style":    true,
			"refactor": true,
			"perf":     true,
			"test":     true,
			"build":    true,
			"ci":       true,
			"chore":    true,
			"revert":   true,
		},
		maxSubjectLength: 72,
		commitPattern:    regexp.MustCompile(`^(?:HYPERFLEET-\d+\s*-\s*)?([a-z]+):\s+(.*)$`),
		jiraPattern:      regexp.MustCompile(`^HYPERFLEET-\d+\s*-\s*`),
		whitelistedAuthors: map[string]bool{
			"konflux@no-reply.konflux-ci.dev":          true,
			"red-hat-konflux-kflux-prd-rh02[bot]":      true,
		},
	}
}

// Validate validates a commit message
func (v *Validator) Validate(message string) *ValidationResult {
	result := &ValidationResult{
		Valid:  true,
		Errors: make([]*ValidationError, 0),
	}

	if message == "" {
		result.Valid = false
		result.Errors = append(result.Errors, &ValidationError{
			Rule:    "message-empty",
			Message: "commit message cannot be empty",
		})
		return result
	}

	lines := strings.Split(message, "\n")
	header := strings.TrimSpace(lines[0])

	if header == "" {
		result.Valid = false
		result.Errors = append(result.Errors, &ValidationError{
			Rule:    "header-empty",
			Message: "commit header cannot be empty",
		})
		return result
	}

	headerWithoutJira := v.jiraPattern.ReplaceAllString(header, "")
	if len(headerWithoutJira) > v.maxSubjectLength {
		result.Valid = false
		result.Errors = append(result.Errors, &ValidationError{
			Rule: "header-max-length",
			Message: fmt.Sprintf(
				"header must not exceed %d characters (excluding JIRA prefix), got %d",
				v.maxSubjectLength, len(headerWithoutJira)),
		})
	}

	matches := v.commitPattern.FindStringSubmatch(header)
	if matches == nil {
		result.Valid = false
		result.Errors = append(result.Errors, &ValidationError{
			Rule:    "header-format",
			Message: "header must match format: [HYPERFLEET-XXX - ]<type>: <subject>",
		})
		return result
	}

	commitType := matches[1]
	subject := matches[2]

	if !v.validTypes[commitType] {
		result.Valid = false
		validTypesStr := v.getValidTypesString()
		result.Errors = append(result.Errors, &ValidationError{
			Rule:    "type-enum",
			Message: fmt.Sprintf("type must be one of [%s], got '%s'", validTypesStr, commitType),
		})
	}

	if strings.TrimSpace(subject) == "" {
		result.Valid = false
		result.Errors = append(result.Errors, &ValidationError{
			Rule:    "subject-empty",
			Message: "subject cannot be empty",
		})
	}

	return result
}

// ValidateFile validates a commit message from a file
func (v *Validator) ValidateFile(filePath string) (*ValidationResult, error) {
	content, err := readFile(filePath)
	if err != nil {
		return nil, fmt.Errorf("failed to read commit message file: %w", err)
	}

	return v.Validate(content), nil
}

// ValidatePRTitle validates a PR title, requiring both valid commit format and JIRA prefix.
func (v *Validator) ValidatePRTitle(title string) *ValidationResult {
	result := v.Validate(title)

	if result.Valid && !v.jiraPattern.MatchString(title) {
		result.Valid = false
		result.Errors = append(result.Errors, &ValidationError{
			Rule:    "pr-title-requires-jira",
			Message: "PR title must include JIRA ticket (format: HYPERFLEET-XXX - <type>: <subject>)",
		})
	}

	return result
}

// IsWhitelistedAuthor returns true if the given identifier (email or GitHub login) belongs to a whitelisted bot account.
func (v *Validator) IsWhitelistedAuthor(identifier string) bool {
	return v.whitelistedAuthors[strings.ToLower(identifier)]
}

func (v *Validator) getValidTypesString() string {
	types := make([]string, 0, len(v.validTypes))
	for t := range v.validTypes {
		types = append(types, t)
	}
	sort.Strings(types)
	return strings.Join(types, ", ")
}
