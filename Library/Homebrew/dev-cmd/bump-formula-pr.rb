# frozen_string_literal: true

require "formula"
require "cli/parser"

module Homebrew
  module_function

  def bump_formula_pr_args
    Homebrew::CLI::Parser.new do
      usage_banner <<~EOS
        `bump-formula-pr` [<options>] [<formula>]

        Create a pull request to update <formula> with a new URL or a new tag.

        If a <URL> is specified, the <SHA-256> checksum of the new download should also
        be specified. A best effort to determine the <SHA-256> and <formula> name will
        be made if either or both values are not supplied by the user.

        If a <tag> is specified, the Git commit <revision> corresponding to that tag
        must also be specified.

        *Note:* this command cannot be used to transition a formula from a
        URL-and-SHA-256 style specification into a tag-and-revision style specification,
        nor vice versa. It must use whichever style specification the formula already uses.
      EOS
      switch "--devel",
             description: "Bump the development rather than stable version. The development spec must already exist."
      switch "-n", "--dry-run",
             description: "Print what would be done rather than doing it."
      switch "--write",
             depends_on:  "--dry-run",
             description: "When passed along with `--dry-run`, perform a not-so-dry run by making the expected "\
                          "file modifications but not taking any Git actions."
      switch "--no-audit",
             description: "Don't run `brew audit` before opening the PR."
      switch "--strict",
             description: "Run `brew audit --strict` before opening the PR."
      switch "--no-browse",
             description: "Print the pull request URL instead of opening in a browser."
      switch "--no-fork",
             description: "Don't try to fork the repository."
      flag   "--mirror=",
             description: "Use the specified <URL> as a mirror URL."
      flag   "--version=",
             description: "Use the specified <version> to override the value parsed from the URL or tag. Note "\
                          "that `--version=0` can be used to delete an existing version override from a "\
                          "formula if it has become redundant."
      flag   "--message=",
             description: "Append <message> to the default pull request message."
      flag   "--url=",
             description: "Specify the <URL> for the new download. If a <URL> is specified, the <SHA-256> "\
                          "checksum of the new download should also be specified."
      flag   "--sha256=",
             depends_on:  "--url=",
             description: "Specify the <SHA-256> checksum of the new download."
      flag   "--tag=",
             description: "Specify the new git commit <tag> for the formula."
      flag   "--revision=",
             required_for: "--tag=",
             description:  "Specify the new git commit <revision> corresponding to the specified <tag>."
      switch :force
      switch :quiet
      switch :verbose
      switch :debug
      conflicts "--no-audit", "--strict"
      conflicts "--url", "--tag"
    end
  end

  def use_correct_linux_tap(formula)
    if OS.linux? && formula.tap.core_tap?
      tap_full_name = formula.tap.full_name.gsub("linuxbrew", "homebrew")
      homebrew_core_url = "https://github.com/#{tap_full_name}"
      homebrew_core_remote = "homebrew"
      homebrew_core_branch = "master"
      origin_branch = "#{homebrew_core_remote}/#{homebrew_core_branch}"
      previous_branch = Utils.popen_read("git -C \"#{formula.tap.path}\" symbolic-ref -q --short HEAD").chomp
      previous_branch = "master" if previous_branch.empty?
      formula_path = formula.path.to_s[%r{(Formula\/.*)}, 1]

      if args.dry_run?
        ohai "git remote add #{homebrew_core_remote} #{homebrew_core_url}"
        ohai "git fetch #{homebrew_core_remote} #{homebrew_core_branch}"
        ohai "git cat-file -e #{origin_branch}:#{formula_path}"
        ohai "git checkout #{origin_branch}"
        return tap_full_name, origin_branch, previous_branch
      else
        formula.path.parent.cd do
          unless Utils.popen_read("git remote -v").match?(%r{^homebrew.*Homebrew\/homebrew-core.*$})
            ohai "Adding #{homebrew_core_remote} remote"
            safe_system "git", "remote", "add", homebrew_core_remote, homebrew_core_url
          end
          ohai "Fetching #{origin_branch}"
          safe_system "git", "fetch", homebrew_core_remote, homebrew_core_branch
          if quiet_system "git", "cat-file", "-e", "#{origin_branch}:#{formula_path}"
            ohai "#{formula.full_name} exists in #{origin_branch}"
            safe_system "git", "checkout", origin_branch
            return tap_full_name, origin_branch, previous_branch
          end
        end
      end
    end
    [formula.tap&.full_name, "origin/master", "-"]
  end

  def bump_formula_pr
    bump_formula_pr_args.parse

    # As this command is simplifying user run commands then let's just use a
    # user path, too.
    ENV["PATH"] = ENV["HOMEBREW_PATH"]

    # Use the user's browser, too.
    ENV["BROWSER"] = ENV["HOMEBREW_BROWSER"]

    formula = Homebrew.args.formulae.first

    if formula
      tap_full_name, origin_branch, previous_branch = use_correct_linux_tap(formula)
      check_for_duplicate_pull_requests(formula, tap_full_name)
      checked_for_duplicates = true
    end

    new_url = args.url
    if new_url && !formula
      # Split the new URL on / and find any formulae that have the same URL
      # except for the last component, but don't try to match any more than the
      # first five components since sometimes the last component isn't the only
      # one to change.
      new_url_split = new_url.split("/")
      maximum_url_components_to_match = 5
      components_to_match = [new_url_split.count - 1, maximum_url_components_to_match].min
      base_url = new_url_split.first(components_to_match).join("/")
      base_url = /#{Regexp.escape(base_url)}/
      is_devel = args.devel?
      guesses = []
      Formula.each do |f|
        if is_devel && f.devel && f.devel.url && f.devel.url.match(base_url)
          guesses << f
        elsif f.stable&.url && f.stable.url.match(base_url)
          guesses << f
        end
      end
      if guesses.count == 1
        formula = guesses.shift
      elsif guesses.count > 1
        odie "Couldn't guess formula for sure; could be one of these:\n#{guesses}"
      end
    end
    raise FormulaUnspecifiedError unless formula

    check_for_duplicate_pull_requests(formula, tap_full_name) unless checked_for_duplicates

    requested_spec, formula_spec = if args.devel?
      devel_message = " (devel)"
      [:devel, formula.devel]
    else
      [:stable, formula.stable]
    end
    odie "#{formula}: no #{requested_spec} specification found!" unless formula_spec

    hash_type, old_hash = if (checksum = formula_spec.checksum)
      [checksum.hash_type, checksum.hexdigest]
    end

    new_hash = args[hash_type] if hash_type
    new_tag = args.tag
    new_revision = args.revision
    new_mirror = args.mirror
    forced_version = args.version
    new_url_hash = if new_url && new_hash
      true
    elsif new_tag && new_revision
      false
    elsif !hash_type
      odie "#{formula}: no --tag=/--revision= arguments specified!"
    elsif !new_url
      odie "#{formula}: no --url= argument specified!"
    else
      new_mirror ||= case new_url
      when requested_spec != :devel && %r{.*ftp.gnu.org/gnu.*}
        new_url.sub "ftp.gnu.org/gnu", "ftpmirror.gnu.org"
      when %r{.*mirrors.ocf.berkeley.edu/debian.*}
        new_url.sub "mirrors.ocf.berkeley.edu/debian", "mirrorservice.org/sites/ftp.debian.org/debian"
      end
      resource = Resource.new { @url = new_url }
      resource.download_strategy = DownloadStrategyDetector.detect_from_url(new_url)
      resource.owner = Resource.new(formula.name)
      resource.version = forced_version if forced_version
      odie "No --version= argument specified!" unless resource.version
      resource_path = resource.fetch
      tar_file_extensions = %w[.tar .tb2 .tbz .tbz2 .tgz .tlz .txz .tZ]
      if tar_file_extensions.any? { |extension| new_url.include? extension }
        gnu_tar_gtar_path = HOMEBREW_PREFIX/"opt/gnu-tar/bin/gtar"
        gnu_tar_gtar = gnu_tar_gtar_path if gnu_tar_gtar_path.executable?
        tar = which("gtar") || gnu_tar_gtar || which("tar")
        if Utils.popen_read(tar, "-tf", resource_path).match?(%r{/.*\.})
          new_hash = resource_path.sha256
        else
          odie "#{resource_path} is not a valid tar file!"
        end
      else
        new_hash = resource_path.sha256
      end
    end

    old_formula_version = formula_version(formula, requested_spec)

    replacement_pairs = []
    if requested_spec == :stable && formula.revision.nonzero?
      replacement_pairs << [
        /^  revision \d+\n(\n(  head "))?/m,
        "\\2",
      ]
    end

    replacement_pairs += formula_spec.mirrors.map do |mirror|
      [
        / +mirror \"#{Regexp.escape(mirror)}\"\n/m,
        "",
      ]
    end

    replacement_pairs += if new_url_hash
      [
        [
          /#{Regexp.escape(formula_spec.url)}/,
          new_url,
        ],
        [
          old_hash,
          new_hash,
        ],
      ]
    else
      [
        [
          formula_spec.specs[:tag],
          new_tag,
        ],
        [
          formula_spec.specs[:revision],
          new_revision,
        ],
      ]
    end

    backup_file = File.read(formula.path) unless args.dry_run?

    if new_mirror
      replacement_pairs << [
        /^( +)(url \"#{Regexp.escape(new_url)}\"\n)/m,
        "\\1\\2\\1mirror \"#{new_mirror}\"\n",
      ]
    end

    if forced_version && forced_version != "0"
      if requested_spec == :stable
        if File.read(formula.path).include?("version \"#{old_formula_version}\"")
          replacement_pairs << [
            old_formula_version.to_s,
            forced_version,
          ]
        elsif new_mirror
          replacement_pairs << [
            /^( +)(mirror \"#{new_mirror}\"\n)/m,
            "\\1\\2\\1version \"#{forced_version}\"\n",
          ]
        else
          replacement_pairs << [
            /^( +)(url \"#{new_url}\"\n)/m,
            "\\1\\2\\1version \"#{forced_version}\"\n",
          ]
        end
      elsif requested_spec == :devel
        replacement_pairs << [
          /(  devel do.+?version \")#{old_formula_version}(\"\n.+?end\n)/m,
          "\\1#{forced_version}\\2",
        ]
      end
    elsif forced_version && forced_version == "0"
      if requested_spec == :stable
        replacement_pairs << [
          /^  version \"[\w\.\-\+]+\"\n/m,
          "",
        ]
      elsif requested_spec == :devel
        replacement_pairs << [
          /(  devel do.+?)^ +version \"[^\n]+\"\n(.+?end\n)/m,
          "\\1\\2",
        ]
      end
    end
    new_contents = inreplace_pairs(formula.path, replacement_pairs)

    new_formula_version = formula_version(formula, requested_spec, new_contents)

    if new_formula_version < old_formula_version
      formula.path.atomic_write(backup_file) unless args.dry_run?
      odie <<~EOS
        You probably need to bump this formula manually since changing the
        version from #{old_formula_version} to #{new_formula_version} would be a downgrade.
      EOS
    elsif new_formula_version == old_formula_version
      formula.path.atomic_write(backup_file) unless args.dry_run?
      odie <<~EOS
        You probably need to bump this formula manually since the new version
        and old version are both #{new_formula_version}.
      EOS
    end

    alias_rename = alias_update_pair(formula, new_formula_version)
    if alias_rename.present?
      ohai "renaming alias #{alias_rename.first} to #{alias_rename.last}"
      alias_rename.map! { |a| formula.tap.alias_dir/a }
    end

    run_audit(formula, alias_rename, backup_file)

    formula.path.parent.cd do
      branch = "#{formula.name}-#{new_formula_version}"
      git_dir = Utils.popen_read("git rev-parse --git-dir").chomp
      shallow = !git_dir.empty? && File.exist?("#{git_dir}/shallow")
      changed_files = [formula.path]
      changed_files += alias_rename if alias_rename.present?

      if args.dry_run?
        ohai "try to fork repository with GitHub API" unless args.no_fork?
        ohai "git fetch --unshallow origin" if shallow
        ohai "git add #{alias_rename.first} #{alias_rename.last}" if alias_rename.present?
        ohai "git checkout --no-track -b #{branch} #{origin_branch}"
        ohai "git commit --no-edit --verbose --message='#{formula.name} " \
             "#{new_formula_version}#{devel_message}' -- #{changed_files.join(" ")}"
        ohai "git push --set-upstream $HUB_REMOTE #{branch}:#{branch}"
        ohai "git checkout --quiet #{previous_branch}"
        ohai "create pull request with GitHub API"
      else

        if args.no_fork?
          remote_url = Utils.popen_read("git remote get-url --push origin").chomp
          username = formula.tap.user
        else
          remote_url, username = forked_repo_info(formula, tap_full_name, backup_file)
        end

        safe_system "git", "fetch", "--unshallow", "origin" if shallow
        safe_system "git", "add", *alias_rename if alias_rename.present?
        safe_system "git", "checkout", "--no-track", "-b", branch, origin_branch
        safe_system "git", "commit", "--no-edit", "--verbose",
                    "--message=#{formula.name} #{new_formula_version}#{devel_message}",
                    "--", *changed_files
        safe_system "git", "push", "--set-upstream", remote_url, "#{branch}:#{branch}"
        safe_system "git", "checkout", "--quiet", previous_branch
        pr_message = <<~EOS
          Created with `brew bump-formula-pr`.
        EOS
        user_message = args.message
        if user_message
          pr_message += "\n" + <<~EOS
            ---

            #{user_message}
          EOS
        end
        pr_title = "#{formula.name} #{new_formula_version}#{devel_message}"

        begin
          url = GitHub.create_pull_request(tap_full_name, pr_title,
                                           "#{username}:#{branch}", "master", pr_message)["html_url"]
          if args.no_browse?
            puts url
          else
            exec_browser url
          end
        rescue *GitHub.api_errors => e
          odie "Unable to open pull request: #{e.message}!"
        end
      end
    end
  end

  def forked_repo_info(formula, tap_full_name, backup_file)
    response = GitHub.create_fork(tap_full_name)
  rescue GitHub::AuthenticationFailedError, *GitHub.api_errors => e
    formula.path.atomic_write(backup_file)
    odie "Unable to fork: #{e.message}!"
  else
    # GitHub API responds immediately but fork takes a few seconds to be ready.
    sleep 1 until GitHub.check_fork_exists(tap_full_name)
    remote_url = if system("git", "config", "--local", "--get-regexp", "remote\..*\.url", "git@github.com:.*")
      response.fetch("ssh_url")
    else
      response.fetch("clone_url")
    end
    username = response.fetch("owner").fetch("login")
    [remote_url, username]
  end

  def inreplace_pairs(path, replacement_pairs)
    if args.dry_run?
      contents = path.open("r") { |f| Formulary.ensure_utf8_encoding(f).read }
      contents.extend(StringInreplaceExtension)
      replacement_pairs.each do |old, new|
        ohai "replace #{old.inspect} with #{new.inspect}" unless Homebrew.args.quiet?
        raise "No old value for new value #{new}! Did you pass the wrong arguments?" unless old

        contents.gsub!(old, new)
      end
      raise Utils::InreplaceError, path => contents.errors unless contents.errors.empty?

      path.atomic_write(contents) if args.write?
      contents
    else
      Utils::Inreplace.inreplace(path) do |s|
        replacement_pairs.each do |old, new|
          ohai "replace #{old.inspect} with #{new.inspect}" unless Homebrew.args.quiet?
          raise "No old value for new value #{new}! Did you pass the wrong arguments?" unless old

          s.gsub!(old, new)
        end
      end
      path.open("r") { |f| Formulary.ensure_utf8_encoding(f).read }
    end
  end

  def formula_version(formula, spec, contents = nil)
    name = formula.name
    path = formula.path
    if contents
      Formulary.from_contents(name, path, contents, spec).version
    else
      Formulary::FormulaLoader.new(name, path).get_formula(spec).version
    end
  end

  def fetch_pull_requests(formula, tap_full_name)
    GitHub.issues_for_formula(formula.name, tap_full_name: tap_full_name).select do |pr|
      pr["html_url"].include?("/pull/") &&
        /(^|\s)#{Regexp.quote(formula.name)}(:|\s|$)/i =~ pr["title"]
    end
  rescue GitHub::RateLimitExceededError => e
    opoo e.message
    []
  end

  def check_for_duplicate_pull_requests(formula, tap_full_name)
    pull_requests = fetch_pull_requests(formula, tap_full_name)
    return unless pull_requests
    return if pull_requests.empty?

    duplicates_message = <<~EOS
      These open pull requests may be duplicates:
      #{pull_requests.map { |pr| "#{pr["title"]} #{pr["html_url"]}" }.join("\n")}
    EOS
    error_message = "Duplicate PRs should not be opened. Use --force to override this error."
    if Homebrew.args.force? && !Homebrew.args.quiet?
      opoo duplicates_message
    elsif !Homebrew.args.force? && Homebrew.args.quiet?
      odie error_message
    elsif !Homebrew.args.force?
      odie <<~EOS
        #{duplicates_message.chomp}
        #{error_message}
      EOS
    end
  end

  def alias_update_pair(formula, new_formula_version)
    versioned_alias = formula.aliases.grep(/^.*@\d+(\.\d+)?$/).first
    return if versioned_alias.nil?

    name, old_alias_version = versioned_alias.split("@")
    new_alias_regex = (old_alias_version.split(".").length == 1) ? /^\d+/ : /^\d+\.\d+/
    new_alias_version, = *new_formula_version.to_s.match(new_alias_regex)
    return if Version.create(new_alias_version) <= Version.create(old_alias_version)

    [versioned_alias, "#{name}@#{new_alias_version}"]
  end

  def run_audit(formula, alias_rename, backup_file)
    if args.dry_run?
      if args.no_audit?
        ohai "Skipping `brew audit`"
      elsif args.strict?
        ohai "brew audit --strict #{formula.path.basename}"
      else
        ohai "brew audit #{formula.path.basename}"
      end
      return
    end
    FileUtils.mv alias_rename.first, alias_rename.last if alias_rename.present?
    failed_audit = false
    if args.no_audit?
      ohai "Skipping `brew audit`"
    elsif args.strict?
      system HOMEBREW_BREW_FILE, "audit", "--strict", formula.path
      failed_audit = !$CHILD_STATUS.success?
    else
      system HOMEBREW_BREW_FILE, "audit", formula.path
      failed_audit = !$CHILD_STATUS.success?
    end
    return unless failed_audit

    formula.path.atomic_write(backup_file)
    FileUtils.mv alias_rename.last, alias_rename.first if alias_rename.present?
    odie "brew audit failed!"
  end
end
