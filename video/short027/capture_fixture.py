"""Invented, provider-shaped mail and real local files for the v0.2.7 film.
All addresses are reserved examples. Never loads personal settings or mail.
"""
from __future__ import annotations
import base64, copy, json, shutil, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT/'video/capture'), str(ROOT/'tests')]
from promo_fixture import fixture as base_fixture, ACCOUNTS, WORK, png
from terminal_integration import Client, require
from terminal_invitations import part
from probes.cache_refresh_fixture import repage
MEETING_ID = 'promo-work-096'
BOOKING_ID = 'promo-work-095'
REPORT_ID = 'promo-work-094'
MEETING_SUBJECT = 'Launch briefing — small eruptions 🌋'
BOOKING_SUBJECT = 'Your Ember Air booking — Vienna to Lisbon ✈️'
REPORT_SUBJECT = 'Release notes — one calm inbox, three useful ideas ✨'
NOTE = '''Hi Maya,

**Our Lisbon trip is confirmed!** Here is the original booking, with its layout intact. ✈️

- Window seat secured
- One carry-on each
- More time for pastries

| Plan | When |
| --- | --- |
| Departure | Friday, 16 Oct |
| Coffee | Before boarding |

See you at the airport — [trip notes](https://example.test/lisbon) are ready.

`hello, Lisbon` 🌋
'''
COMPOSE_BODY = '''# A calmer inbox. A better day. 🌋

Hi Maya,

The launch notes are ready. **Small details make a big difference.**

- Find what matters
- Choose files together
- Undo before it leaves

| Feature | Ready |
| --- | --- |
| Meetings | One key |
| Compose | Beautiful |

```python
def hello():
    print("Hello, volcano!")
```

[Read the notes](https://example.test/notes) · `something`
'''
BOOKING_HTML = '''<!doctype html><html lang="en"><head><meta charset="utf-8"><style>
body{margin:0;background:#f3f4f6;color:#23323a;font-family:Arial,Helvetica,sans-serif}table{border-collapse:collapse}td{vertical-align:top}.card{background:#fff;border:1px solid #e1e5e8}.muted{color:#73818a}.route{font-size:34px;font-weight:700;letter-spacing:-1px}.tiny{font-size:12px;letter-spacing:2px;text-transform:uppercase}
</style></head><body bgcolor="#f3f4f6"><table width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:28px"><table class="card" width="640" cellpadding="0" cellspacing="0"><tr><td style="padding:24px 32px;border-bottom:4px solid #eb7c43"><table width="100%"><tr><td><span style="font-size:22px;font-weight:700;letter-spacing:3px">EMBER AIR</span><br><span class="tiny muted">A little closer to somewhere good</span></td><td align="right"><img src="cid:ember-mark@example.test" width="48" height="48" alt="Ember Air mark"></td></tr></table></td></tr><tr><td style="padding:28px 32px 12px"><p class="tiny muted" style="margin:0 0 10px">BOOKING CONFIRMED · EA7LIS</p><h1 style="margin:0;font-size:25px">Lisbon is calling. ✈️</h1><p style="line-height:1.6;margin:10px 0">Hello Morgan, your journey is booked.<br>Here are the details for your next small adventure.</p></td></tr><tr><td style="padding:12px 32px"><img src="cid:ember-sunset@example.test" width="576" height="110" alt="Warm sunset gradient" style="display:block;border-radius:10px"></td></tr><tr><td style="padding:20px 32px"><table width="100%"><tr><td><span class="tiny muted">VIENNA</span><br><span class="route">VIE</span><br><span style="font-size:18px">09:30</span></td><td align="center" style="padding-top:18px;color:#eb7c43;font-size:30px">→</td><td align="right"><span class="tiny muted">LISBON</span><br><span class="route">LIS</span><br><span style="font-size:18px">11:55</span></td></tr></table></td></tr><tr><td style="padding:0 32px 22px"><table width="100%" style="font-size:14px;border-top:1px solid #e1e5e8"><tr><td style="padding:14px 0">Friday, 16 October 2026</td><td align="right" style="padding:14px 0">Flight EA 370 · Direct</td></tr><tr><td style="padding:10px 0;border-top:1px solid #eef0f2">Passenger</td><td align="right" style="padding:10px 0;border-top:1px solid #eef0f2"><b>Morgan Hills</b></td></tr><tr><td style="padding:10px 0;border-top:1px solid #eef0f2">Seat · Baggage</td><td align="right" style="padding:10px 0;border-top:1px solid #eef0f2">12A · One carry-on</td></tr></table><p style="margin:14px 0 0"><a href="https://example.test/booking/EA7LIS" style="color:#d7672f;text-decoration:underline">Manage your booking →</a></p></td></tr><tr><td class="muted" style="padding:18px 32px;background:#fafafa;font-size:12px">Fictional booking for the Omagma demonstration. No real travel data.</td></tr></table></td></tr></table></body></html>'''
BOOKING_TEXT = 'Lisbon is calling. ✈️\n\nYour Ember Air booking is confirmed.\nVienna VIE → Lisbon LIS\nFriday, 16 October 2026 · Flight EA 370\n09:30 → 11:55 · Seat 12A · One carry-on\nPassenger: Morgan Hills\nBooking: EA7LIS\n\nManage your booking: https://example.test/booking/EA7LIS\n'
FIND_TEXT = '''Release notes — one calm inbox.

The little things matter.

1. A calm inbox keeps the right message selected.
2. A calm inbox lets you find details without leaving the reader.
3. A calm inbox has room for the next small eruption. 🌋

Keyboard-first. Mouse-friendly. Yours.
'''
FILES = ('eruption-agenda.md','eruption-briefing.pdf','eruption-budget.csv','eruption-checklist.txt','eruption-colors.json','eruption-logo.png','eruption-notes.md','eruption-preview.html','eruption-slides.pdf','eruption-team.csv')

def payload_headers(message, subject, sender):
    headers = copy.deepcopy(message['payload']['headers'])
    for header in headers:
        name = header['name'].lower()
        if name == 'subject': header['value'] = subject
        elif name == 'from': header['value'] = sender
        elif name == 'content-type': header['value'] = 'multipart/mixed'
    return headers

def make(directory):
    source = base_fixture(directory)
    (source.root/'contacts').mkdir(mode=0o700,exist_ok=True)
    config = json.loads((ROOT/'tests/fixtures/all-accounts.json').read_text())
    for row in config['accounts']:
        row.update(senderName='Morgan Hills',signature='Morgan Hills\nSent with a little less noise.')
    config_file=directory/'synthetic-config.json';config_file.write_text(json.dumps(config));config_file.chmod(0o600)
    for account in ACCOUNTS:
        key=account.split('@')[0]
        contacts=json.loads((ROOT/'tests/fixtures/terminal/contacts'/f'{key}.json').read_text())
        contacts['connections'][0]['names'][0]['displayName']='Maya Chen'
        contacts['connections'][0]['emailAddresses']=[{'value':'maya@example.org','type':'work'},{'value':'maya-home@example.net','type':'home'}]
        (source.root/'contacts'/f'{key}.json').write_text(json.dumps(contacts))
        data=source.data[account]['baseline']
        data['identities']=[{'address':account,'name':'Morgan Hills','signature':'Morgan Hills\nSent with a little less noise.','isDefault':True},{'address':'launch@example.test','name':'Morgan · Launch team','signature':'Morgan · Launch team','isDefault':False}]
        data['labels']=[{'id':'INBOX','name':'Inbox','type':'system'},{'id':'STARRED','name':'Starred','type':'system'},{'id':'UNREAD','name':'Unread','type':'system'},{'id':'Label_projects','name':'Projects','type':'user','color':{'backgroundColor':'#fb4c2f','textColor':'#ffffff'}},{'id':'Label_travel','name':'Travel','type':'user','color':{'backgroundColor':'#4986e7','textColor':'#ffffff'}},{'id':'Label_follow','name':'Follow up','type':'user','color':{'backgroundColor':'#a479e2','textColor':'#ffffff'}}]
        for index,msg in enumerate(data['messages'][:8]):
            if index in (0,1):msg['labelIds'] += ['Label_projects']
            if index==0:msg['labelIds'] += ['STARRED','Label_follow']
            if index==1:msg['labelIds'] += ['Label_travel']
        if account==WORK:
            meeting,booking,report=data['messages'][:3]
            calendar='\r\n'.join(['BEGIN:VCALENDAR','VERSION:2.0','PRODID:-//Omagma Demo//EN','METHOD:REQUEST','BEGIN:VEVENT','UID:launch-briefing@example.test','DTSTAMP:20261009T080000Z','SEQUENCE:1','SUMMARY:Launch briefing — small eruptions 🌋','DTSTART:20261012T080000Z','DTEND:20261012T082000Z','LOCATION:Online · Launch studio','ORGANIZER;CN=Maya Chen:mailto:maya@example.org',f'ATTENDEE;CN=Morgan Hills;RSVP=TRUE;PARTSTAT=NEEDS-ACTION:mailto:{WORK}','DESCRIPTION:Launch notes and next steps. Join: https://meet.example.test/launch','URL:https://meet.example.test/launch','END:VEVENT','END:VCALENDAR','']).encode()
            meeting['snippet']='Monday, 10:00 local · 20 minutes · One key to join.'
            meeting['payload']={'partId':'','mimeType':'multipart/mixed','filename':'','headers':payload_headers(meeting,MEETING_SUBJECT,'Maya Chen <maya@example.org>'),'body':{'size':0},'parts':[part('text/plain',b'Hi Morgan,\n\nA quick launch briefing on Monday.\nWe will review the release, share the next steps, and leave time for questions.\n\nAgenda\n- A calmer inbox\n- A smoother composer\n- The next small eruption\n\nSee you there!\nMaya\n'),part('text/calendar',calendar,'invite.ics')]}
            booking['snippet']='Your trip is confirmed. Original layout, images, and booking details.'
            booking['payload']={'partId':'','mimeType':'multipart/related','filename':'','headers':payload_headers(booking,BOOKING_SUBJECT,'Ember Air <booking@ember.example.org>'),'body':{'size':0},'parts':[part('text/html',BOOKING_HTML.encode()),part('image/png',png(96,96),'ember-mark.png'),part('image/png',png(576,110),'ember-sunset.png')]}
            for item,cid in zip(booking['payload']['parts'][1:],('ember-mark@example.test','ember-sunset@example.test')):
                item['headers']=[{'name':'Content-Type','value':'image/png'},{'name':'Content-Disposition','value':'inline; filename="'+item['filename']+'"'},{'name':'Content-ID','value':'<'+cid+'>'}]
            report['snippet']='Three useful ideas. Find the details in the reader.'
            report['payload']={'partId':'','mimeType':'text/plain','filename':'','headers':payload_headers(report,REPORT_SUBJECT,'Harbor Workshop <notes@harbor.example.net>'),'body':{'size':len(FIND_TEXT.encode()),'data':base64.urlsafe_b64encode(FIND_TEXT.encode()).decode().rstrip('=')}}
        repage(data);source.stage(account,'baseline')
    documents=directory/'Documents';documents.mkdir(mode=0o700)
    manifest=[]
    for i,name in enumerate(FILES):
        value=(ROOT/'assets/omagma-logo.png').read_bytes() if name.endswith('.png') else ('Fictional '+name+'\n').encode()+b'0'*(180+i*319)
        (documents/name).write_bytes(value);manifest.append({'filename':name,'bytes':len(value)})
    (documents/'other-project.txt').write_text('Nonmatching file is hidden by the filter.\n')
    (directory/'home').mkdir(mode=0o700,exist_ok=True)
    return source,config_file,manifest

def options(source,config_file,*extra):return (*source.options(), '--config',str(config_file),*extra)
def seed(binary,directory,source,config):
    with Client(binary,directory,extra=options(source,config)) as client:
        for account in ACCOUNTS:
            client.request('mail.refresh',account,label='INBOX',limit=32,prefetchLimit=8)
            client.request('labels.list',account)
            client.request('contacts.list',account)
            client.request('accounts.identities',account)
        for message in (MEETING_ID,BOOKING_ID,REPORT_ID):client.request('mail.read',WORK,messageId=message,cacheOnly=True)
        require(client.request('cache.stats',WORK)['fixtureSends']==0,'synthetic seeding sent mail')
