#!/usr/bin/env ruby

# Converts Unfuddle XML backups to CSV readable by JIRA.

require 'active_support/core_ext/enumerable'
require 'active_support/core_ext/hash/conversions'
require 'active_support/core_ext/hash/indifferent_access'
require 'active_support/inflector'
require 'csv'
require 'fileutils'

# Speed holes: parses a 90M Unfuddle XML file 10x faster than the default parser.
ActiveSupport::XmlMini.backend = 'LibXML'

PROJECT_KEY = 'LUTEST' # Your JIRA project short name

# Custom mappings of Unfuddle -> JIRA usernames, e.g. { 'unfuddleJohn' => 'jiraJohn' }
CUSTOM_USER_MAPPINGS = { }
# Offset for numbering the imported JIRA issues (if your JIRA project has tickets in it already).
# The importer will try to preserve issue numbers for issues above this number; ones below it will
# get imported with later issue numbers, or will fill in gaps if there are missing numbers.
ISSUE_NUMBER_OFFSET = 0

# Username to attach to importer comments and actions
IMPORT_USER = 'importbot'

BACKUP_FILE = 'backup.complete/backup.xml'
ATTACHMENTS_DIR = 'backup.complete/media/attachments'
OUTPUT_FILE = 'output.csv'

class UnfuddleToJira
  def initialize
    puts 'Parsing XML (this may take a while)…'
    @doc = init_doc
    puts 'Parsing milestones…'
    @milestones = init_milestones
    puts 'Parsing tickets…'
    @tickets = init_tickets
    puts 'Converting Unfuddle ticket numbers into JIRA issue keys…'
    @jira_issue_numbers = init_jira_issue_numbers
    @max_comments = @tickets.collect { |t| t[:comments].size }.max
    @max_links = @tickets.collect { |t| t[:associated_tickets].size }.max
  end

  def start
    CSV.open(OUTPUT_FILE, 'wb') do |csv|
      puts 'Writing header…'
      csv << csv_header

      puts 'Writing milestones…'
      @milestones.values.each { |milestone| csv << csv_for_milestone(milestone) }

      puts 'Writing tickets and comments…'
      @tickets.each { |ticket| csv << csv_for_ticket(ticket) }

      puts 'Renaming attachments…'
      @tickets.each { |ticket| rename_attachments(ticket) }
    end
  end

  private

  def convert_markdown(text)
    if text.nil?
      nil
    else
      text.gsub(
        # Code blocks with language
        /```([a-z]+)(.*?)```/m, '{code:\1}\2{code}').gsub(
        # Code blocks without language
        /```(.*?)```/m, '{code}\1{code}').gsub(
        # Monospaced text
        /`([^`]+?)`/, '{{\1}}').gsub(
        # Links
        /\[(.+?)\]\s*\(([^\)]+)\)/m, '[\1|\2]')
    end
  end

  def csv_header
    ['unfuddle-number', 'jira-issue-key', 'issue-type', 'title', 'status', 'assignee', 'reporter',
      'resolution', 'severity', 'created-at', 'updated-at', 'due-on', 'resolved-at', 'epic-name',
      'epic-link', 'description'] + custom_field_titles +
      (['associated-ticket-number'] * @max_links) + (['comment'] * @max_comments)
  end

  def csv_for_milestone(milestone)
    [nil, jira_issue_key_for(milestone), 'Epic', milestone[:title], milestone_status(milestone),
      people[milestone[:person_responsible_id]], nil, nil, nil, milestone[:created_at],
      milestone[:updated_at], timestamp_for(milestone[:due_on]), nil, milestone_name(milestone),
      nil, convert_markdown(milestone[:description]), nil, nil, nil]
  end

  def csv_for_ticket(ticket)
    ticket_url = unfuddle_project_url + '/tickets/by_number/' + ticket[:number]
    comments = [[ticket[:updated_at], IMPORT_USER,
      "Migrated from Unfuddle ##{ticket[:number]}: #{ticket_url}"].join(';')]

    # JIRA has no resolution description; add as a comment
    if ticket[:resolution] && ticket[:resolution_description]
      comments << [ticket[:updated_at], IMPORT_USER,
        'Resolution: ' + ticket[:resolution_description].gsub(';', '.')].join(';')
    end

    associated_ticket_numbers = ticket[:associated_tickets].collect { |t| t[:number] }

    comments += ticket[:comments].collect do |comment|
      [comment[:created_at], people[comment[:author_id].to_i],
        convert_markdown(comment[:body]).gsub(';', '.')].join(';')
    end

    [ticket[:number], jira_issue_key_for(ticket), 'Story', ticket[:summary], ticket[:status],
      people[ticket[:assignee_id].to_i], people[ticket[:reporter_id].to_i], ticket[:resolution],
      severity_names[ticket[:severity_id]], ticket[:created_at], ticket[:updated_at],
      timestamp_for(ticket[:due_on]), (ticket[:resolution] ? ticket[:updated_at] : nil), nil,
      milestone_name(@milestones[ticket[:milestone_id]]), convert_markdown(ticket[:description]),
      custom_field_value('1', ticket[:field1_value_id]),
      custom_field_value('2', ticket[:field2_value_id]),
      custom_field_value('3', ticket[:field1_value_id])] +
      associated_ticket_numbers.fill(nil, associated_ticket_numbers.size...@max_links) + comments
  end

  def custom_field_titles
    [project[:ticket_field1_title], project[:ticket_field2_title], project[:ticket_field3_title]]
  end

  def custom_field_value(field_number, value_id)
    field_values = project[:custom_field_values]
    field_value = field_values.find { |f| f[:field_number] == field_number && f[:id] == value_id }
    field_value.try(:[], :value) || value_id
  end

  def first_unused_number(list)
    list.zip(list[1..-1]).find { |x, y| x + 1 != y }[0] + 1
  end

  def init_doc
    xml = Hash.from_xml(File.read(BACKUP_FILE).gsub("\f", ' ')).with_indifferent_access[:account]
    normalize_to_list!(xml, :projects)
    normalize_to_list!(xml, :people)
    normalize_to_list!(xml[:projects][0], :custom_field_values)
    normalize_to_list!(xml[:projects][0], :milestones)
    normalize_to_list!(xml[:projects][0], :tickets)
    normalize_to_list!(xml[:projects][0], :severities)
    xml
  end

  def init_jira_issue_numbers
    jira_issue_numbers = {}

    # Match issue numbers to JIRA numbers where possible
    @tickets.select { |t| t[:number].to_i > ISSUE_NUMBER_OFFSET }.each do |ticket|
      jira_issue_numbers[ticket] = ticket[:number].to_i
    end

    # Fill in the rest
    @tickets.select { |t| t[:number].to_i <= ISSUE_NUMBER_OFFSET }.each do |ticket|
      jira_issue_numbers[ticket] = first_unused_number(jira_issue_numbers.values.sort)
    end

    # Milestones don't have Unfuddle numbers, so stick them at the end.
    @milestones.values.each do |milestone|
      jira_issue_numbers[milestone] = first_unused_number(jira_issue_numbers.values.sort)
    end

    jira_issue_numbers
  end

  def init_milestones
    milestones = Hash[
      project[:milestones].collect do |milestone|
        [milestone[:id], milestone]
      end
    ]

    milestone_names = milestones.values.collect { |milestone| milestone_name(milestone) }
    duplicate_names = milestone_names.group_by { |e| e }.select { |k, v| v.size > 1 }.map(&:first)

    duplicate_names.each do |name|
      duplicates = milestones.values.select { |milestone| milestone_name(milestone) == name }

      duplicates.each_with_index do |milestone, index|
        milestone[:title] = milestone[:title] + "-#{index + 1}"
        puts "Renamed duplicate milestone to #{milestone[:title]}"
      end
    end

    milestones
  end

  def init_tickets
    tickets_from_xml = project[:tickets]
    tickets_from_xml.sort! { |x, y| x[:number].to_i <=> y[:number].to_i }

    tickets_from_xml.each do |ticket|
      normalize_to_list!(ticket, :comments)
      normalize_to_list!(ticket, :attachments)
      normalize_to_list!(ticket, :associated_tickets, nested_key: :ticket)

      ticket[:comments].each do |comment|
        normalize_to_list!(comment, :attachments)
      end
    end

    # Make sure each associated ticket is linked only one direction to avoid duplication
    tickets_from_xml.each do |ticket|
      ticket[:associated_tickets].each do |associated_ticket|
        related_ticket = tickets_from_xml.find { |t| t[:number] == associated_ticket[:number] }

        related_ticket[:associated_tickets].select! do |backlink|
          backlink[:number] != ticket[:number]
        end
      end
    end

    tickets_from_xml
  end

  def jira_issue_key_for(ticket_or_milestone)
    "#{PROJECT_KEY}-#{@jira_issue_numbers[ticket_or_milestone]}"
  end

  def milestone_name(milestone)
    (milestone.try(:[], :title) || '').gsub(/\s+/, '-').gsub(/[^\w_-]/, '')
  end

  def milestone_status(milestone)
    milestone[:completed] == 'true' || milestone[:archived] == 'true' ? 'closed' : 'new'
  end

  # Normalize the value in a hash generated by Hash.from_xml so that e.g. ticket[:attachments] is
  # guaranteed to be a list of those objects. Hash.from_xml otherwise ends up with a whitespace
  # string for an empty list, a single-element Hash instead of a list for one element, or a list
  # with the items we want nested in a sub-list like ticket[:attachments][:attachment].
  def normalize_to_list!(obj, key, nested_key: ActiveSupport::Inflector.singularize(key))
    if obj[key].is_a?(Hash)
      if obj[key][nested_key].is_a?(Hash)
        obj[key] = [obj[key][nested_key]]
      else
        obj[key] = obj[key][nested_key]
      end
    elsif obj[key].is_a?(String)
      obj[key] = []
    end
  end

  def people
    @people ||= Hash[@doc[:people].collect { |person| [person[:id], person_name(person)] }]
  end

  def person_name(person)
    name = person[:username] || 'term_' + person[:first_name].downcase
    CUSTOM_USER_MAPPINGS[name] || name
  end

  def project
    @doc[:projects][0]
  end

  def rename_attachments(ticket)
    comments = ticket[:comments]
    comment_attachments = comments.collect { |comment| comment[:attachments] }.reduce(:+) || []

    (ticket[:attachments] + comment_attachments).each do |attachment|
      rename_attachment(ticket, attachment)
    end
  end

  def rename_attachment(ticket, attachment)
    id = attachment[:id]
    filename = attachment[:filename]
    new_filename = "#{id}_#{filename}"
    old_file = File.join(ATTACHMENTS_DIR, id)
    new_dir = File.join(ATTACHMENTS_DIR, PROJECT_KEY, jira_issue_key_for(ticket))
    new_file = File.join(new_dir, new_filename)

    if File.exist?(new_file)
      puts "Skipping attachment #{id}; found renamed file at #{new_file}."
    else
      puts "Renaming attachment #{id} to #{new_file}"
      FileUtils.mkdir_p new_dir
      File.rename(old_file, new_file)
    end
  end

  def severity_names
    @severity_names ||= Hash[
      project[:severities].collect { |severity| [severity[:id], severity[:name]] }
    ]
  end

  def timestamp_for(simple_date)
    simple_date.present? ? simple_date + 'T00:00:00Z' : nil
  end

  def unfuddle_project_url
    "https://#{@doc[:subdomain]}.unfuddle.com/a#/projects/#{project[:id]}"
  end
end

UnfuddleToJira.new.start
