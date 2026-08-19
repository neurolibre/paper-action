require "yaml"

# Fill gaps in a paper.md front matter from the project's myst.yml.
#
# A NeuroLibre submission declares its title, authors and affiliations in
# myst.yml for the living preprint. inara can already build the paper from
# myst.yml alone (data/filters/myst-frontmatter.lua), but the metadata step that
# runs before it -- Theoj::Paper, via get_paper.rb -- re-parses paper.md and
# raises on a front matter without an `authors` or `affiliations` key. This
# module gives the Ruby side the same fallback, so the pipeline can reach the
# capability the filter already has.
#
# It mirrors data/filters/myst-frontmatter.lua in neurolibre/inara and
# api/myst_frontmatter.py in neurolibre/full-stack-server. Any rule changed here
# must be changed in all three.
#
# The fallback is best-effort by design: a missing, unreadable or malformed
# myst.yml leaves the metadata exactly as it was. It must never be the reason a
# build fails.
module MystFallback
  MYST_FILE = "myst.yml".freeze

  # Parts of a myst.yml affiliation, joined into the single name string the
  # gem's Author and inara's templates expect. Department precedes institution
  # to match the convention in existing NeuroLibre front matter.
  NAME_PARTS = %w[department institution address city region postal_code country].freeze

  # MyST's accepted aliases for those parts.
  PART_ALIASES = { "institution" => "name", "region" => "state" }.freeze

  # How far above the paper to look for myst.yml before giving up.
  MAX_ASCENT = 8

  module_function

  # Returns metadata with any key that myst.yml can supply and paper.md left
  # blank filled in. `metadata` may be anything YAML.load_file returned,
  # including the String a paper.md with no front matter yields.
  def apply(metadata, paper_path, root = nil)
    metadata = {} unless metadata.is_a?(Hash)
    project = read_project(paper_path, root)
    return metadata if project.nil?

    filled = []
    fill = lambda do |key, value|
      next unless blank?(metadata[key])
      next if blank?(value)
      metadata[key] = value
      filled << key
    end

    fill.call("title", project["title"])
    fill.call("date", project["date"])
    fill.call("tags", project["keywords"])
    fill.call("bibliography", project["bibliography"])

    # Authors and affiliations are filled as a pair. An affiliation index only
    # means something relative to the list that defines it, so mixing paper.md
    # authors with myst.yml affiliations would silently attach authors to the
    # wrong institutions.
    if blank?(metadata["authors"]) || blank?(metadata["affiliations"])
      affiliations, index_of = build_affiliations(project)
      authors = build_authors(project, affiliations, index_of)
      unless authors.empty?
        metadata["authors"] = authors
        metadata["affiliations"] = affiliations
        filled.concat(%w[authors affiliations])
      end
    end

    warn "[INFO] myst-fallback: filled from #{MYST_FILE}: #{filled.join(', ')}" unless filled.empty?
    metadata
  end

  # Read the `project` mapping out of the myst.yml nearest the paper, or nil.
  def read_project(paper_path, root)
    path = find_myst(paper_path, root)
    return nil if path.nil?

    parsed = YAML.load_file(path)
    return nil unless parsed.is_a?(Hash)

    project = parsed["project"]
    project.is_a?(Hash) ? project : nil
  rescue StandardError => e
    warn "[INFO] myst-fallback: ignoring #{MYST_FILE} (#{e.class}: #{e.message})"
    nil
  end

  # myst.yml sits at the repository root; paper.md may sit in a subdirectory, so
  # walk up from the paper. `root` bounds the walk to the cloned repository when
  # the caller knows it.
  def find_myst(paper_path, root)
    return nil if paper_path.to_s.strip.empty?

    dir = File.expand_path(File.dirname(paper_path))
    stop = root.to_s.strip.empty? ? nil : File.expand_path(root)

    MAX_ASCENT.times do
      candidate = File.join(dir, MYST_FILE)
      return candidate if File.file?(candidate)

      parent = File.dirname(dir)
      break if parent == dir
      break if stop && dir == stop

      dir = parent
    end

    nil
  end

  # A key that is present but carries nothing counts as absent. `authors:` with
  # no value parses to nil, `authors: []` to an empty Array; both mean the same
  # thing to a submitter, and treating either as present defeats the fallback.
  def blank?(value)
    case value
    when nil then true
    when String then value.strip.empty?
    when Array, Hash then value.empty?
    else false
    end
  end

  # `affiliations: harvard` is legal MyST. Treat any non-Array as a
  # one-element sequence rather than iterating it.
  def as_list(value)
    return [] if value.nil?
    value.is_a?(Array) ? value : [value]
  end

  # Read one affiliation part, honouring MyST's aliases.
  def part(aff, key)
    value = aff[key]
    value = aff[PART_ALIASES[key]] if value.nil? && PART_ALIASES.key?(key)
    value
  end

  # Join an affiliation's parts into the one name string the gem expects.
  def affiliation_name(aff)
    NAME_PARTS.filter_map do |key|
      value = part(aff, key)
      text = value.to_s.strip
      text.empty? ? nil : text
    end.join(", ")
  end

  # Build the indexed affiliation list and an id -> index map.
  #
  # MyST's validator accepts a bare string where an affiliation mapping is
  # expected. Such an entry becomes an affiliation named by that string, with no
  # id, and it still consumes its index position -- the Lua and Python sides
  # apply the same rule, so all three agree on every author's index.
  def build_affiliations(project)
    affiliations = []
    index_of = {}

    as_list(project["affiliations"]).each_with_index do |aff, i|
      index = (i + 1).to_s
      if aff.is_a?(Hash)
        affiliations << { "index" => index, "name" => affiliation_name(aff) }
        index_of[aff["id"].to_s] = index unless aff["id"].nil?
      else
        affiliations << { "index" => index, "name" => aff.to_s }
      end
    end

    [affiliations, index_of]
  end

  # MyST accepts a list, a single id, or several ids in one ';'-separated
  # string. Declared order is preserved.
  def affiliation_tokens(value)
    return [] if value.nil?
    return value.map { |entry| entry.to_s.strip }.reject(&:empty?) if value.is_a?(Array)

    value.to_s.split(";").map(&:strip).reject(&:empty?)
  end

  # Build the author list, resolving affiliation ids to indices.
  #
  # A token matching no declared id is an ad-hoc affiliation: it is appended
  # under its own index with that literal name, because dropping the author's
  # affiliation would be worse than inventing an entry for it.
  #
  # As with affiliations, a bare string in place of an author mapping is legal
  # MyST; it becomes an author of that name with no affiliations, keeping its
  # position in the list.
  def build_authors(project, affiliations, index_of)
    as_list(project["authors"]).map do |source|
      next { "name" => source.to_s } unless source.is_a?(Hash)

      author = { "name" => source["name"].to_s }
      author["email"] = source["email"] unless blank?(source["email"])
      author["orcid"] = source["orcid"] unless blank?(source["orcid"])
      author["corresponding"] = source["corresponding"] unless source["corresponding"].nil?
      author["equal-contrib"] = source["equal_contributor"] unless source["equal_contributor"].nil?

      tokens = affiliation_tokens(source["affiliations"] || source["affiliation"])
      indices = tokens.map do |token|
        index = index_of[token]
        if index.nil?
          index = (affiliations.length + 1).to_s
          affiliations << { "index" => index, "name" => token }
          index_of[token] = index
        end
        index
      end
      author["affiliation"] = indices.join(",") unless indices.empty?

      author
    end
  end
end
