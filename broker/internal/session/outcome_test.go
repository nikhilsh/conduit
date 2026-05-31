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
	}{
		{"open", `{"number":412,"state":"OPEN","isDraft":false}`, 412, "open"},
		{"draft", `{"number":399,"state":"OPEN","isDraft":true}`, 399, "draft"},
		{"merged", `{"number":408,"state":"MERGED","isDraft":false}`, 408, "merged"},
		{"closed", `{"number":401,"state":"CLOSED","isDraft":false}`, 401, "closed"},
		{"no pr (empty)", "", 0, ""},
		{"no number", `{"state":"OPEN"}`, 0, ""},
		{"garbage", "no such pr", 0, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			n, st := parseGHPR([]byte(c.in))
			if n != c.wantNum || st != c.wantState {
				t.Fatalf("parseGHPR(%q) = (%d,%q), want (%d,%q)", c.in, n, st, c.wantNum, c.wantState)
			}
		})
	}
}
