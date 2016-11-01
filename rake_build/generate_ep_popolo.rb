
#-----------------------------------------------------------------------
# Transform the results from generic CSV-to-Popolo into EP-Popolo
#
#   - remove all Executive Memberships
#   - merge legislature data from meta.json
#     - ensure all legislative memberships are on that
#   - merge term data from terms.csv
#-----------------------------------------------------------------------
namespace :transform do
  file 'ep-popolo-v1.0.json' => :write
  CLEAN.include('ep-popolo-v1.0.json', 'final.json')

  task load: MERGED_JSON do
    @json = JSON.parse(MERGED_JSON.read, symbolize_names: true)
  end

  task :write do
    popolo_write('ep-popolo-v1.0.json', @json)
  end

  #---------------------------------------------------------------------
  # Rule: There must be a single legislature
  #---------------------------------------------------------------------
  task write: :ensure_legislature
  task ensure_legislature: :load do
    # Clean out legislative memberships
    @json[:memberships].delete_if { |m| m[:organization_id] == 'executive' }
    @json[:organizations].delete_if { |h| h[:classification] == 'executive' }

    legis = @json[:organizations].select { |h| h[:classification] == 'legislature' }
    raise "Legislature count = #{legis.count}" unless legis.count == 1
    @legislature = legis.first

    # Remake 'chamber' memberships to the full legislature
    @json[:organizations].select { |h| h[:classification] == 'chamber' }.each do |c|
      @json[:memberships].select { |m| m[:organization_id] == c[:id] }.each do |m|
        m[:organization_id] = @legislature[:id]
      end
    end
    @json[:organizations].delete_if { |h| h[:classification] == 'chamber' }
  end

  #---------------------------------------------------------------------
  # Set legislature data from meta.json file
  #---------------------------------------------------------------------
  task write: :name_legislature
  task name_legislature: :ensure_legislature do
    raise 'No meta.json file available' unless File.exist? 'meta.json'
    meta_info = json_load('meta.json')
    @legislature.merge! meta_info
    (@legislature[:identifiers] ||= []) << {
      scheme:     'wikidata',
      identifier: @legislature.delete(:wikidata),
    } if @legislature.key?(:wikidata)

    # Switch the legislature ID everywhere it's used
    @json[:memberships].select { |m| m[:organization_id] == @legislature[:id] }.each do |m|
      m[:organization_id] = @legislature[:uuid]
    end
    @json[:posts].select { |m| m[:organization_id] == @legislature[:id] }.each do |m|
      m[:organization_id] = @legislature[:uuid]
    end
    @legislature[:id] = @legislature.delete :uuid
  end

  #---------------------------------------------------------------------
  # Merge with terms.csv
  #---------------------------------------------------------------------
  task write: :ensure_term

  def terms_from_csv
    termfiles = Dir.glob('sources/**/terms.csv')
    raise 'No terms.csv' if termfiles.count.zero?
    raise "Too many terms.csv [#{termfiles}]" if termfiles.count > 1

    CSV.read(termfiles.first, headers: true).reject(&:empty?).map do |row|
      {
        id:              row['id'][/\//] ? row['id'] : "term/#{row['id']}",
        name:            row['name'],
        start_date:      row['start_date'],
        end_date:        row['end_date'],
        identifiers:     row['wikidata'].to_s.empty? ? [] : [{
          scheme:     'wikidata',
          identifier: row['wikidata']
        }],
        classification:  'legislative period',
        organization_id: @legislature[:id],
      }.reject { |_, v| v.nil? || v.empty? }
    end
  end

  task ensure_term: :ensure_legislature do
    @json[:events].each do |e|
      (csv_term = terms_from_csv.find { |t| t[:id] == e[:id] }) || abort("No term information for #{e[:id]}")
      e.merge! csv_term
    end
  end

  #---------------------------------------------------------------------
  # Don't duplicate start/end dates into memberships needlessly
  #   and ensure they're within the term
  #---------------------------------------------------------------------
  task write: :tidy_memberships
  task tidy_memberships: :ensure_term do
    @json[:memberships].each do |m|
      (e = @json[:events].find { |e| e[:id] == m[:legislative_period_id] }) || abort("#{m[:legislative_period_id]} is not a term")

      m.delete :start_date if m[:start_date].to_s.empty? || (!e[:start_date].to_s.empty? && m[:start_date].to_s <= e[:start_date].to_s)
      m.delete :end_date   if m[:end_date].to_s.empty?   || (!e[:end_date].to_s.empty?   && m[:end_date].to_s   >= e[:end_date].to_s)
    end
    duplicates = @json[:memberships].group_by { |m| m }.select { |_, ms| ms.size > 1 }.map(&:first)
    if duplicates.any?
      duplicates.each do |dupe|
        warn "Discarding duplicate membership: #{dupe}".yellow
      end
      @json[:memberships].uniq!
    end
  end

  #---------------------------------------------------------------------
  # Rule: Legislative Memberships must have `on_behalf_of`
  #---------------------------------------------------------------------
  def unknown_party
    if unknown = @json[:organizations].find { |o| o[:classification] == 'party' && o[:name].downcase == 'unknown' }
      return unknown
    end
    unknown = {
      classification: 'party',
      name:           'Unknown',
      id:             'party/_unknown',
    }
    @json[:organizations] << unknown
    unknown
  end

  task write: :ensure_behalf_of
  task ensure_behalf_of: :ensure_legislature do
    leg_ids = @json[:organizations].select { |o| %w(legislature chamber).include? o[:classification] }.map { |o| o[:id] }
    @json[:memberships].select { |m| m[:role] == 'member' && leg_ids.include?(m[:organization_id]) }.each do |m|
      m[:on_behalf_of_id] = unknown_party[:id] if m[:on_behalf_of_id].to_s.empty?
    end
  end

  #---------------------------------------------------------------------
  # Rule: Areas should be first class, not just embedded
  #---------------------------------------------------------------------
  task write: :check_no_embedded_areas
  task check_no_embedded_areas: :ensure_legislature do
    raise 'Memberships should not have embedded areas' if @json[:memberships].any? { |m| m.key? :area }
  end

  #---------------------------------------------------------------------
  # Remap gender to consistent format
  #---------------------------------------------------------------------
  task write: :remap_gender
  GENDER_MAP = {
    'male'   => %w(m male homme),
    'female' => ['f', 'female', 'femme', 'transgender female'],
    'other'  => %w(o other),
  }.freeze

  task remap_gender: :load do
    remap = Hash[GENDER_MAP.flat_map { |k, vs| vs.map { |v| [v, k] } }]
    @json[:persons].each do |p|
      next if p[:gender].to_s.empty?
      p[:gender] = remap[p[:gender].downcase.strip] || raise("Unknown gender: #{p[:gender]}")
    end
  end

  #---------------------------------------------------------------------
  # Add Election information
  #---------------------------------------------------------------------
  task write: :election_info
  task election_info: :load do
    @INSTRUCTIONS.sources_of_type('wikidata-elections').each do |src|
      @json[:events] += src.to_popolo[:events]
    end
  end

  #---------------------------------------------------------------------
  # Merge area wikidata information
  #---------------------------------------------------------------------
  task write: :area_wikidata
  task area_wikidata: :load do
    @INSTRUCTIONS.sources_of_type('area-wikidata').each do |src|
      src.to_popolo[:areas].each do |area|
        @json[:areas].select do |a|
          a[:type] == 'constituency' &&
          a[:id].split('/').last == area[:id].split('/').last
        end.each do |existing|
          existing.merge!(area) do |key, old, new|
            key == :id ? old : new
          end
        end
      end
    end
  end

  #---------------------------------------------------------------------
  # Merge group wikidata information
  #---------------------------------------------------------------------
  task write: :group_wikidata
  task group_wikidata: :load do
    @INSTRUCTIONS.sources_of_type('group').each do |src|
      src.to_popolo[:organizations].each do |org|
        matched = @json[:organizations].select do |o|
          o[:classification] == 'party' &&
          o[:id].split('/').last.downcase == org[:id].split('/').last.downcase
        end
        warn "Party #{org[:id]} not in Popolo" unless matched.any?
        matched.each do |existing|
          existing.merge!(org) do |key, old, new|
            key == :id ? old : new
          end
        end
      end
    end
  end
end
