# Home Page Rework — Design

**Status:** Approved for planning
**Relates to:** `koha-plugin-store-spec.md` §12 ("Developer-facing home page"); build order (§11) step 4

## Summary

Replaces `templates/site/index.html.ep`, which currently just duplicates the "All Plugins"
listing (redundant with `/plugins`, which already exists as its own page), with a page that
actually orients a first-time visitor: what the store is, who it's for, and how to join —
per §12. Stacks on `worktree-submission-pipeline`, since the join/submit path it links to
(`/auth/github`, `/new-plugin`) only makes sense once login and submission both work
end-to-end.

Pure template + controller change. No new routes, no new queries, no schema change, no new
CSS system — Bootstrap 5 utilities (already the site's only styling) cover it.

## Two states, one template

The page branches on the existing `logged_in_user` helper, the same way
`partial/auth_menu.html.ep` already does — no new helper needed.

**Anonymous visitor** gets the pitch and join path (the three things §12 requires):

1. **What it is** — a "Koha Plugin Store" heading plus a one-paragraph lead: a
   community-run plugin catalogue for Koha, where developers submit and manage their own
   plugins.
2. **Who it's for** — a distinct callout (Bootstrap `alert-info`) stating explicitly that
   this UI is for plugin *developers*; Koha instances and library staff discover plugins
   from inside Koha itself, not here. This exists specifically to head off confused
   librarians/patrons landing here expecting a plugin browser (§12).
3. **How to join** — three numbered steps (log in with GitHub → pick one of your repos →
   choose a tagged release to submit), followed by a "Log in with GitHub" button.

**Logged-in developer** gets a compact welcome-back panel instead: avatar + username (both
already on the `Developer` model/`logged_in_user` helper — no new data needed), and two
direct actions, "Submit a new plugin" (`/new-plugin`) and "View my plugins" (`/my-plugins`).
The join-path steps don't repeat here — a returning developer doesn't need reminding how to
log in.

Neither block is factored into a partial: both are single-use content specific to this one
page, and nothing else will reuse them. `partial/side_menu`, `partial/table/plugins`, etc.
were split out because they're shared across pages — that doesn't apply here.

## Link targets

- The "Log in with GitHub" CTA links straight to `/auth/github`, not `/login`. §12 calls for
  linking "straight into the actual login/submission routes rather than describing them
  abstractly" — `/login` is just an interstitial page with one GitHub button on it, so
  going straight to `/auth/github` saves a click. The standalone `/login` page is untouched
  and still reachable from the sidebar for direct nav/bookmarks.
- "Submit a new plugin" → `/new-plugin`, "View my plugins" → `/my-plugins` — both existing,
  authenticated routes.

## Controller change

`Controller::Site::index` currently fetches every plugin via
`KohaPluginStore::Model::Plugin->new(pg => $c->pg)->search` purely to feed the listing table
this rework removes. That query and its stash become dead weight and are deleted; `index`
becomes a plain `$c->render`. `logged_in_user` is a template helper already available
without any stash wiring, so the template needs nothing else from the controller.

## Non-goals

- No dynamic content (recently-published plugins, plugin counts, activity feed). Discussed
  explicitly and deferred: it's not one of §12's three required elements, it would add a
  query and a bit of design surface, and the page's job is orientation, not a dashboard.
  Revisit if real user feedback asks for it.
- No changes to `/plugins` (the existing "All Plugins" listing) or site navigation
  (`partial/side_menu.html.ep`'s "Home"/"All Plugins" links already point at the right,
  distinct routes and don't need to change).
- No new CSS. `main.css` currently holds only the loading-overlay/spinner rules; this page
  needs nothing beyond Bootstrap utility classes (`alert`, `btn`, `list-group` or a couple
  of `card`s).

## Testing

- `t/` gets a small `Test::Mojo` coverage update for `GET /`: anonymous request shows the
  "Log in with GitHub" CTA and the who-it's-for callout, doesn't show plugin-listing markup;
  logged-in request (via the existing mock/session-seeding pattern used elsewhere in the
  suite) shows the welcome-back panel with the developer's username and doesn't show the
  join-path steps.
- No fixture changes needed — existing seeded developer/session helpers cover both states.
