Importer script for moving Unfuddle tickets to JIRA.

This includes some newer functionality JIRA enabled that aren't covered by existing Unfuddle/JIRA
migration scripts: in particular, comments, milestones as proper epics, ticket linking,
custom select-field value mappings, and attachments.

Follow the directions under the Unfuddle project settings to get your project's
[backups](https://unfuddle.com/stack/docs/help/backups/). Extract the `backup.complete` directory
from the archives to the same directory as the `unfuddle_to_jira.rb` script. Edit the Ruby script
to set `PROJECT_NAME`, `ISSUE_NUMBER_OFFSET`, and `IMPORT_USER`. Set `CUSTOM_USER_MAPPINGS` if
you have existing JIRA users whose usernames are different than the ones they used in Unfuddle, and
set `BACKUP_FILE` and `ATTACHMENTS_DIR` if your Unfuddle backup lives somewhere else. Since this
script will rename attachment files from the backup, you should keep the original backup archive
around locally in case you need to start over from scratch without re-downloading your backup.

Install the script's dependencies with `bundle install`, then run the script:

```
bundle exec ./unfuddle_to_jira.rb
```
Caveats:

* Milestones that are archived or completed are closed; all other milestones will be left open.
* Custom field value mappings are tested with single-selects, and nothing else at the moment.
* All ticket links are mapped to one type in the CSV, regardless of parent/child/duplicate
  relationship status in Unfuddle.
* Severity is pulled in, but currently not priority (for historical reasons specific to our
  project).
* We assume comments, descriptions, etc. are written in Markdown in Unfuddle. Only a few basic bits
  of Markdown from Unfuddle are converted to JIRA's proprietary syntax. JIRA OnDemand currently has
  no way to render Markdown directly, so more advanced formatting may be mangled.
* Attachment files aren't included in the CSV, but are moved/renamed to subfolders that can then
  be uploaded via JIRA's [bulk attachment upload
  script](https://confluence.atlassian.com/display/JIRAKB/Bulk+import+attachments+via+REST+API).
* Comment attachments are converted to attachments on the associated tickets; JIRA's importer can't
  do comment-specific attachments.

Note that there are some invalid characters that can be passed through in Unfuddle's XML; you may
need to remove those manually for this to process.

The included sample importer config, `jira-importer-config.txt`, can be uploaded to JIRA along with
your CSV as a starting point. You'll need to select 'Map Field Value' for the `status`,
`resolution`, `severity`, and `issue-type` fields to map to your particular JIRA setup's field values, as well
as any custom field mappings you might have.

For more technical details, see JIRA's documentation on[CSV
imports](https://confluence.atlassian.com/display/JIRA/Importing+Data+from+CSV) and [the file
format](https://confluence.atlassian.com/display/JIRA/Creating+issues+using+the+CSV+importer).
