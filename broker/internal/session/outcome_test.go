package session

import "testing"

func TestParseShortstat(t *testing.T) {
	cases := []struct {
		name      string
		in        string
		wantAdded int
		wantRem   int
	}{
		{"both", " 7 files changed, 24 insertions(+), 9 deletions(-)\n", 24, 9},
		{"insertions only", " 1 file changed, 5 insertions(+)\n", 5, 0},
		{"deletions only", " 2 files changed, 880 deletions(-)\n", 0, 880},
		{"singular insertion", " 1 file changed, 1 insertion(+)\n", 1, 0},
		{"singular deletion", " 1 file changed, 1 deletion(-)\n", 0, 1},
		{"empty (no changes)", "", 0, 0},
		{"garbage", "not a shortstat line", 0, 0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			a, r := parseShortstat(c.in)
			if a != c.wantAdded || r != c.wantRem {
				t.Fatalf("parseShortstat(%q) = (%d,%d), want (%d,%d)", c.in, a, r, c.wantAdded, c.wantRem)
			}
		})
	}
}

func TestParseGHPR(t *testing.T) {
	cases := []struct {
		name      string
		in        string
		wantNum   int
		wantState string
		wantURL   string
	}{
		{"open", `{"number":412,"state":"OPEN","isDraft":false,"url":"https://github.com/org/repo/pull/412"}`, 412, "open", "https://github.com/org/repo/pull/412"},
		{"draft", `{"number":399,"state":"OPEN","isDraft":true,"url":"https://github.com/org/repo/pull/399"}`, 399, "draft", "https://github.com/org/repo/pull/399"},
		{"merged", `{"number":408,"state":"MERGED","isDraft":false,"url":"https://github.com/org/repo/pull/408"}`, 408, "merged", "https://github.com/org/repo/pull/408"},
		{"closed", `{"number":401,"state":"CLOSED","isDraft":false,"url":"https://github.com/org/repo/pull/401"}`, 401, "closed", "https://github.com/org/repo/pull/401"},
		{"no url field", `{"number":412,"state":"OPEN","isDraft":false}`, 412, "open", ""},
		{"no pr (empty)", "", 0, "", ""},
		{"no number", `{"state":"OPEN"}`, 0, "", ""},
		{"garbage", "no such pr", 0, "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			n, st, url := parseGHPR([]byte(c.in))
			if n != c.wantNum || st != c.wantState || url != c.wantURL {
				t.Fatalf("parseGHPR(%q) = (%d,%q,%q), want (%d,%q,%q)", c.in, n, st, url, c.wantNum, c.wantState, c.wantURL)
			}
		})
	}
}

func TestParseGlabMR(t *testing.T) {
	cases := []struct {
		name      string
		in        string
		wantNum   int
		wantState string
		wantURL   string
	}{
		{"opened", `{"iid":42,"state":"opened","web_url":"https://gitlab.com/org/repo/-/merge_requests/42"}`, 42, "open", "https://gitlab.com/org/repo/-/merge_requests/42"},
		{"merged", `{"iid":37,"state":"merged","web_url":"https://gitlab.com/org/repo/-/merge_requests/37"}`, 37, "merged", "https://gitlab.com/org/repo/-/merge_requests/37"},
		{"closed", `{"iid":10,"state":"closed","web_url":"https://gitlab.com/org/repo/-/merge_requests/10"}`, 10, "closed", "https://gitlab.com/org/repo/-/merge_requests/10"},
		{"no iid", `{"state":"opened","web_url":"https://gitlab.com/org/repo/-/merge_requests/0"}`, 0, "", ""},
		{"garbage", "not json", 0, "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			n, st, url := parseGlabMR([]byte(c.in))
			if n != c.wantNum || st != c.wantState || url != c.wantURL {
				t.Fatalf("parseGlabMR(%q) = (%d,%q,%q), want (%d,%q,%q)", c.in, n, st, url, c.wantNum, c.wantState, c.wantURL)
			}
		})
	}
}

func TestProviderForRemote(t *testing.T) {
	cases := []struct {
		name     string
		remote   string
		wantProv string
	}{
		{"github https", "https://github.com/org/repo.git", "github"},
		{"github ssh", "git@github.com:org/repo.git", "github"},
		{"github enterprise", "https://github.example.com/org/repo.git", "github"},
		{"gitlab https", "https://gitlab.com/org/repo.git", "gitlab"},
		{"gitlab ssh", "git@gitlab.com:org/repo.git", "gitlab"},
		{"self-hosted gitlab", "https://git.mycompany.com/gitlab/org/repo.git", "gitlab"},
		{"self-hosted gitlab host", "https://gitlab.mycompany.com/org/repo.git", "gitlab"},
		{"unknown host", "https://bitbucket.org/org/repo.git", ""},
		{"empty", "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := providerForRemote(c.remote)
			if got != c.wantProv {
				t.Fatalf("providerForRemote(%q) = %q, want %q", c.remote, got, c.wantProv)
			}
		})
	}
}
