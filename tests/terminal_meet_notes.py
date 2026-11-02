#!/usr/bin/env python3
"""New-event Meet AI notes: isolated native CLI and provider-state oracles."""
import argparse
import json
from pathlib import Path
import tempfile
from terminal_calendar import Invitations, provider_state
from terminal_integration import Client, ACCOUNTS, require


def event():
    return dict(summary="Fictional planning with automatic notes", start="2026-11-10T10:00", end="2026-11-10T11:00", timeZone="UTC", attendees=[], conference="google_meet")


def review(c, operation="notes-create-one", **extra):
    return c.request("calendar.meet-event-review", calendarId=ACCOUNTS[0], operationId=operation,
                     sendUpdates="none", meetAiNotes="on", event=event(), **extra)


def confirmation(r):
    return {k:r[k] for k in ("account", "calendarId", "operationId", "reviewHash")}


def meet_state(root):
    paths=list((root/"client/cache").rglob("meet-provider-fixture.json"))
    return json.loads(paths[0].read_text()) if paths else dict(writes=0, patch_attempts=0, reads=0, spaces=[])


def main():
    p=argparse.ArgumentParser();p.add_argument("--binary",type=Path,required=True);args=p.parse_args()
    binary=args.binary.resolve();passed=[]
    scenarios=("meet-ready","meet-lost-response","meet-unapplied-unknown","meet-rejected","meet-api-disabled","meet-malformed-response","meet-conference-pending","meet-conference-failed","meet-calendar-lost","meet-read-unavailable","meet-read-dropped","meet-settings-revoked")
    for scenario in scenarios:
        with tempfile.TemporaryDirectory(prefix="omagma-meet-acceptance-") as temp:
            root=Path(temp);fixture=Invitations(root)
            with Client(binary,root/"client",scenario=scenario,extra=fixture.options()) as c:
                r=review(c);confirm=confirmation(r)
                require(provider_state(c)["writes"]==0,"review mutated Calendar")
                require(meet_state(root)["writes"]==0,"review mutated Meet")
                result=c.request("calendar.meet-event-apply",**confirm)
                require(provider_state(c)["writes"]==1,"event was not created exactly once")
                require(result["retryPossible"] is False and "nextAttempt" not in result,"result advertised a nonexistent retry")
                before=meet_state(root)
                c.restart()
                checked=c.request("calendar.meet-event-reconcile",**confirm)
                require(provider_state(c)["writes"]==1,"reconcile repeated event creation")
                require(meet_state(root)["patch_attempts"]==before["patch_attempts"],"reconcile PATCHed Meet")
                if scenario in ("meet-ready","meet-lost-response","meet-malformed-response"):
                    require(checked["meetAiNotes"]["state"]=="on","both settings were not positively verified")
                    state=meet_state(root);require(len(state["spaces"])==1 and state["spaces"][0]["notes"] and state["spaces"][0]["transcription"],"independent fixture state lacks both settings")
                elif scenario=="meet-unapplied-unknown":
                    require(checked["meetAiNotes"]["state"]=="unknown","absent result was falsely confirmed")
                elif scenario in ("meet-rejected","meet-conference-failed"):
                    require(checked["meetAiNotes"]["state"]=="refused","definite refusal was hidden")
                elif scenario in ("meet-api-disabled", "meet-read-unavailable", "meet-read-dropped", "meet-settings-revoked"):
                    require(checked["meetAiNotes"]["state"] in ("not_sent","waiting_for_link"),"transient GET became a terminal refusal")
                elif scenario=="meet-conference-pending":
                    require(checked["meetAiNotes"]["state"]=="waiting_for_link","pending link was falsely ready")
                for _ in range(2):c.request("calendar.meet-event-apply",**confirm)
                require(provider_state(c)["writes"]==1,"same confirmation repeated Calendar write")
                # Calendar-lost is discovered by reconcile, then one explicit first notes dispatch is allowed.
                require(meet_state(root)["patch_attempts"]<=max(1,before["patch_attempts"]),"same confirmation resent Meet")
                require(c.request("cache.stats")["fixtureSends"]==0,"Meet flow sent mail")
                bad=dict(confirm,reviewHash="0"*64)
                require(c.request("calendar.meet-event-apply",ok=False,**bad)["code"]=="MeetReviewMismatch","changed hash was accepted")
            if scenario in ("meet-conference-pending", "meet-api-disabled", "meet-read-unavailable", "meet-read-dropped", "meet-settings-revoked"):
                with Client(binary,root/"client",scenario="meet-finish-ready" if scenario=="meet-conference-pending" else "meet-ready",extra=fixture.options()) as recovered:
                    ready=recovered.request("calendar.meet-event-reconcile",**confirm)
                    require(ready["meetAiNotes"]["phase"]=="ready","read-only recovery did not make the FIRST setting request available")
                    require(meet_state(root)["patch_attempts"]==0,"recovery check sent setting before confirmation")
                    done=recovered.request("calendar.meet-event-apply",**confirm)
                    require(done["meetAiNotes"]["state"]=="on" and provider_state(recovered)["writes"]==1,"explicit first Meet request recreated Calendar event")
            passed.append(scenario)
    with tempfile.TemporaryDirectory(prefix="omagma-meet-contract-") as temp:
        root=Path(temp);fixture=Invitations(root)
        with Client(binary,root/"client",scenario="meet-no-permission",extra=fixture.options()) as c:
            c.request("calendar.list")
            require(c.request("calendar.meet-event-review",ok=False,calendarId=ACCOUNTS[0],operationId="missing-scope",sendUpdates="none",meetAiNotes="on",event=event())["code"]=="MeetSettingsPermissionRequired","missing grant did not block review")
            require(provider_state(c)["writes"]==0,"missing Meet grant created event")
    with tempfile.TemporaryDirectory(prefix="omagma-meet-refuse-extra-") as temp:
        root=Path(temp);fixture=Invitations(root)
        with Client(binary,root/"client",scenario="meet-ready",extra=fixture.options()) as c:
            c.request("calendar.list")
            base=dict(calendarId=ACCOUNTS[0],operationId="scope-contract",sendUpdates="none",meetAiNotes="on",event=event())
            rejected_secondary=c.request("calendar.meet-event-review",ok=False,**(base|dict(calendarId="fixture-shared-team")))
            require(rejected_secondary["code"]=="MeetNotOrganizer","secondary destination did not fail before creation")
            for changed in (dict(eventId="existing"),dict(expectedEtag='"v1"'),dict(meetAiNotes="off"),dict(event=dict(event(),conference="link",joinUrl="https://meet.google.com/abc-defg-hij"))):
                c.request("calendar.meet-event-review",ok=False,**(base|changed))
            for cmd in ("calendar.meet-event-retry","calendar.meet-event-abandon","calendar.meet-ai-default","calendar.meet-ai-status"):
                c.request(cmd,ok=False,calendarId=ACCOUNTS[0],operationId="not-supported")
            require(provider_state(c)["writes"]==0 and meet_state(root)["writes"]==0,"rejected advanced request caused side effects")
    print(json.dumps(dict(ok=True,scenarios=passed,scope="new-events-only",duplicateCalendarWrites=0,automaticRetries=0,fixtureMailSends=0)))


if __name__=="__main__":main()
