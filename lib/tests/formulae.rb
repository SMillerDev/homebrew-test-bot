# frozen_string_literal: true

require "utils/github/artifacts"

module Homebrew
  module Tests
    class Formulae < TestFormulae
      attr_writer :testing_formulae, :added_formulae, :deleted_formulae

      def initialize(tap:, git:, dry_run:, fail_fast:, verbose:, output_paths:)
        super(tap: tap, git: git, dry_run: dry_run, fail_fast: fail_fast, verbose: verbose)

        @built_formulae = []
        (@previously_built_bottle_cache = Pathname("bottle-cache")).mkpath
        @bottle_output_path = output_paths[:bottle]
        @linkage_output_path = output_paths[:linkage]
        @skipped_or_failed_formulae_output_path = output_paths[:skipped_or_failed_formulae]
      end

      def run!(args:)
        # #run! modifies `@testing_formulae`, so we need to track this separately.
        @testing_formulae_count = @testing_formulae.count

        download_previously_built_bottles!

        sorted_formulae.each do |f|
          formula!(f, args: args)
          puts
        end

        @deleted_formulae.each do |f|
          deleted_formula!(f)
          puts
        end

        return unless ENV["GITHUB_ACTIONS"]

        File.open(ENV.fetch("GITHUB_OUTPUT"), "a") do |f|
          f.puts "skipped_or_failed_formulae=#{@skipped_or_failed_formulae.join(",")}"
        end

        @skipped_or_failed_formulae_output_path.write(@skipped_or_failed_formulae.join(","))
      ensure
        @previously_built_bottle_cache.rmtree
      end

      private

      def previous_github_sha
        return if ENV["GITHUB_ACTIONS"].blank?

        @previous_sha ||= begin
          event_path = ENV.fetch("GITHUB_EVENT_PATH")
          event_payload = JSON.parse(File.read(event_path))

          repository_data = event_payload.fetch("repository")
          owner = repository_data.dig("owner", "login")
          repo = repository_data.fetch("name")
          before = event_payload.fetch("before", "")

          if before.present? &&
             repository.directory? &&
             tap.full_name == "#{owner}/#{repo}"
            test git, "-C", repository, "fetch", "origin", before

            before
          else
            ""
          end
        end

        @previous_sha
      end

      GRAPHQL_QUERY = <<~GRAPHQL
        query ($node_id: ID!) {
          node(id: $node_id) {
            ... on Commit {
              checkSuites(last: 100) {
                nodes {
                  status
                  updatedAt
                  workflowRun {
                    databaseId
                    event
                    workflow {
                      name
                    }
                  }
                  checkRuns(last: 100) {
                    nodes {
                      name
                      status
                    }
                  }
                }
              }
            }
          }
        }
      GRAPHQL

      def download_previously_built_bottles!
        return if previous_github_sha.blank?

        repo = ENV.fetch("GITHUB_REPOSITORY")
        url = GitHub.url_to("repos", repo, "commits", previous_github_sha)
        response = GitHub::API.open_rest(url)
        node_id = response.fetch("node_id")

        response = GitHub::API.open_graphql(GRAPHQL_QUERY, variables: { node_id: node_id })
        check_suite_nodes = response.dig("node", "checkSuites", "nodes")
        return if check_suite_nodes.blank?

        formulae_tests_nodes = check_suite_nodes.select do |node|
          next false if node.fetch("status") != "COMPLETED"

          workflow_run = node.fetch("workflowRun")
          next false if workflow_run.fetch("event") != "pull_request"
          next false if workflow_run.dig("workflow", "name") != "CI"

          check_run_nodes = node.dig("checkRuns", "nodes")
          next false if check_run_nodes.blank?

          check_run_nodes.any? do |check_run_node|
            check_run_node.fetch("name") == "conclusion" && check_run_node.fetch("status") == "COMPLETED"
          end
        end
        return if formulae_tests_nodes.blank?

        run_id = formulae_tests_nodes.max_by { |node| Time.parse(node.fetch("updatedAt")) }
                                     .dig("workflowRun", "databaseId")
        return if run_id.blank?

        url = GitHub.url_to("repos", repo, "actions", "runs", run_id, "artifacts")
        response = GitHub::API.open_rest(url)
        return if response.fetch("total_count").zero?

        bottles_artifact = response.fetch("artifacts").find { |artifact| artifact.fetch("name") == "bottles" }
        return if bottles_artifact.blank?

        ohai "Downloading bottles from #{previous_github_sha}"
        download_url = bottles_artifact.fetch("archive_download_url")

        @previously_built_bottle_cache.cd do
          GitHub.download_artifact(download_url, run_id)
        end
      rescue GitHub::API::AuthenticationFailedError => e
        opoo e
      end

      def no_diff?(formula, sha)
        return false unless repository.directory?

        relative_formula_path = formula.path.relative_path_from(repository)
        system(git, "-C", repository, "diff", "--no-ext-diff", "--quiet", sha, relative_formula_path)
      end

      def install_previously_built_bottle?(formula)
        return false if previous_github_sha.blank?
        return false unless no_diff?(formula, previous_github_sha)

        formula.recursive_dependencies.all? do |dep|
          no_diff?(dep.to_formula, previous_github_sha)
        end
      end

      def tap_needed_taps(deps)
        deps.each { |d| d.to_formula.recursive_dependencies }
      rescue TapFormulaUnavailableError => e
        raise if e.tap.installed?

        e.tap.clear_cache
        safe_system "brew", "tap", e.tap.name
        retry
      end

      def install_ca_certificates_if_needed
        return if DevelopmentTools.ca_file_handles_most_https_certificates?

        test "brew", "install", "ca-certificates",
             env: { "HOMEBREW_DEVELOPER" => nil }
      end

      def install_gcc_if_needed(formula, deps)
        installed_gcc = false
        begin
          deps.each { |dep| CompilerSelector.select_for(dep.to_formula) }
          CompilerSelector.select_for(formula)
        rescue CompilerSelectionError => e
          unless installed_gcc
            test "brew", "install", "gcc",
                 env: { "HOMEBREW_DEVELOPER" => nil }
            installed_gcc = true
            DevelopmentTools.clear_version_cache
            retry
          end
          skipped formula.name, e.message
        end
      end

      def setup_formulae_deps_instances(formula, formula_name, args:)
        conflicts = formula.conflicts
        formula_recursive_dependencies = formula.recursive_dependencies.map(&:to_formula)
        formula_recursive_dependencies.each do |dependency|
          conflicts += dependency.conflicts
        end

        # If we depend on a versioned formula, make sure to unlink any other
        # installed versions to make sure that we use the right one.
        versioned_dependencies = formula_recursive_dependencies.select(&:versioned_formula?)
        versioned_dependencies.each do |dependency|
          alternative_versions = dependency.versioned_formulae

          begin
            unversioned_name = dependency.name.sub(/@\d+(\.\d+)*$/, "")
            alternative_versions << Formula[unversioned_name]
          rescue FormulaUnavailableError
            nil
          end

          unneeded_alternative_versions = alternative_versions - formula_recursive_dependencies
          conflicts += unneeded_alternative_versions
        end

        unlink_formulae = conflicts.map(&:name)
        unlink_formulae.uniq.each do |name|
          unlink_formula = Formulary.factory(name)
          next unless unlink_formula.latest_version_installed?
          next unless unlink_formula.linked_keg.exist?

          test "brew", "unlink", name
        end

        info_header "Determining dependencies..."
        installed = Utils.safe_popen_read("brew", "list", "--formula").split("\n")
        dependencies =
          Utils.safe_popen_read("brew", "deps", "--include-build",
                                "--include-test", formula_name)
               .split("\n")
        installed_dependencies = installed & dependencies
        installed_dependencies.each do |name|
          link_formula = Formulary.factory(name)
          next if link_formula.keg_only?
          next if link_formula.linked_keg.exist?

          test "brew", "link", name
        end

        dependencies -= installed
        @unchanged_dependencies = dependencies - @testing_formulae
        test "brew", "fetch", "--retry", *@unchanged_dependencies unless @unchanged_dependencies.empty?

        changed_dependencies = dependencies - @unchanged_dependencies
        unless changed_dependencies.empty?
          test "brew", "fetch", "--retry", "--build-from-source",
               *changed_dependencies

          ignore_failures = changed_dependencies.any? do |dep|
            !bottled?(Formulary.factory(dep), no_older_versions: true)
          end

          # Install changed dependencies as new bottles so we don't have
          # checksum problems. We have to install all `changed_dependencies`
          # in one `brew install` command to make sure they are installed in
          # the right order.
          test "brew", "install", "--build-from-source",
               named_args:      changed_dependencies,
               ignore_failures: ignore_failures
          # Run postinstall on them because the tested formula might depend on
          # this step
          test "brew", "postinstall", named_args: changed_dependencies, ignore_failures: ignore_failures
        end

        runtime_or_test_dependencies =
          Utils.safe_popen_read("brew", "deps", "--include-test", formula_name)
               .split("\n")
        build_dependencies = dependencies - runtime_or_test_dependencies
        @unchanged_build_dependencies = build_dependencies - @testing_formulae
      end

      def cleanup_bottle_etc_var(formula)
        bottle_prefix = formula.opt_prefix/".bottle"
        # Nuke etc/var to have them be clean to detect bottle etc/var
        # file additions.
        Pathname.glob("#{bottle_prefix}/{etc,var}/**/*").each do |bottle_path|
          prefix_path = bottle_path.sub(bottle_prefix, HOMEBREW_PREFIX)
          FileUtils.rm_rf prefix_path
        end
      end

      def bottle_reinstall_formula(formula, new_formula, args:)
        unless build_bottle?(formula, args: args)
          @bottle_filename = nil
          return
        end

        root_url = args.root_url

        # GitHub Releases url
        root_url ||= if tap.present? && !tap.core_tap? && !@test_default_formula
          "#{tap.default_remote}/releases/download/#{formula.name}-#{formula.pkg_version}"
        end

        # This is needed where sparse files may be handled (bsdtar >=3.0).
        # We use gnu-tar with sparse files disabled when --only-json-tab is passed.
        ENV["HOMEBREW_BOTTLE_SUDO_PURGE"] = "1" if MacOS.version >= :catalina && !args.only_json_tab?

        bottle_args = ["--verbose", "--json", formula.full_name]
        bottle_args << "--keep-old" if args.keep_old? && !new_formula
        bottle_args << "--skip-relocation" if args.skip_relocation?
        bottle_args << "--force-core-tap" if @test_default_formula
        bottle_args << "--root-url=#{root_url}" if root_url
        bottle_args << "--only-json-tab" if args.only_json_tab?
        test "brew", "bottle", *bottle_args

        bottle_step = steps.last
        if !bottle_step.passed? || !bottle_step.output?
          failed formula.full_name, "bottling failed" unless args.dry_run?
          return
        end

        @bottle_output_path.write(bottle_step.output, mode: "a")

        @bottle_filename =
          bottle_step.output
                     .gsub(%r{.*(\./\S+#{HOMEBREW_BOTTLES_EXTNAME_REGEX}).*}om, '\1')
        @bottle_json_filename =
          @bottle_filename.gsub(/\.(\d+\.)?tar\.gz$/, ".json")
        bottle_merge_args =
          ["--merge", "--write", "--no-commit", "--no-all-checks", @bottle_json_filename]
        bottle_merge_args << "--keep-old" if args.keep_old? && !new_formula

        test "brew", "bottle", *bottle_merge_args
        test "brew", "uninstall", "--force", formula.full_name

        bottle_json = JSON.parse(File.read(@bottle_json_filename))
        root_url = bottle_json.dig(formula.full_name, "bottle", "root_url")
        filename = bottle_json.dig(formula.full_name, "bottle", "tags").values.first["filename"]

        # Test bottle is never uploaded, so we need to stub a cached download.
        download_strategy = CurlGitHubPackagesDownloadStrategy.new(
          "#{root_url}/#{filename}",
          formula.name,
          formula.version,
        )
        download_strategy.resolved_basename = File.basename(@bottle_filename)
        download_strategy.cached_location.parent.mkpath
        FileUtils.ln @bottle_filename, download_strategy.cached_location, force: true
        FileUtils.ln_s download_strategy.cached_location.relative_path_from(download_strategy.symlink_location),
                       download_strategy.symlink_location,
                       force: true

        @built_formulae << formula.full_name
        @testing_formulae.delete(formula.name)

        unless @unchanged_build_dependencies.empty?
          test "brew", "uninstall", "--force", *@unchanged_build_dependencies
          @unchanged_dependencies -= @unchanged_build_dependencies
        end

        test "brew", "install", "--only-dependencies", @bottle_filename
        test "brew", "install", @bottle_filename
      end

      def build_bottle?(formula, args:)
        # Build and runtime dependencies must be bottled on the current OS,
        # but accept an older compatible bottle for test dependencies.
        return false if formula.deps.any? do |dep|
          !bottled_or_built?(
            dep.to_formula,
            @built_formulae - @skipped_or_failed_formulae,
            no_older_versions: !dep.test?,
          )
        end

        !args.build_from_source?
      end

      def livecheck(formula)
        return unless formula.livecheckable?
        return if formula.livecheck.skip?

        livecheck_step = test "brew", "livecheck", "--formula", "--json", "--full-name", formula.full_name

        return if livecheck_step.failed?
        return unless livecheck_step.output?

        livecheck_info = JSON.parse(livecheck_step.output)&.first

        if livecheck_info["status"] == "error"
          error_msg = if livecheck_info["messages"].present? && livecheck_info["messages"].length.positive?
            livecheck_info["messages"].join("\n")
          else
            # An error message should always be provided alongside an "error"
            # status but this is a failsafe
            "Error encountered (no message provided)"
          end

          if ENV["GITHUB_ACTIONS"].present?
            puts GitHub::Actions::Annotation.new(
              :error,
              error_msg,
              title: "#{formula}: livecheck error",
              file:  formula.path.to_s.delete_prefix("#{repository}/"),
            )
          else
            onoe error_msg
          end
        end

        # `status` and `version` are mutually exclusive (the presence of one
        # indicates the absence of the other)
        return if livecheck_info["status"].present?

        return if livecheck_info["version"]["newer_than_upstream"] != true

        current_version = livecheck_info["version"]["current"]
        latest_version = livecheck_info["version"]["latest"]

        newer_than_upstream_msg = if current_version.present? && latest_version.present?
          "The formula version (#{current_version}) is newer than the " \
            "version from `brew livecheck` (#{latest_version})."
        else
          "The formula version is newer than the version from `brew livecheck`."
        end

        if ENV["GITHUB_ACTIONS"].present?
          puts GitHub::Actions::Annotation.new(
            :warning,
            newer_than_upstream_msg,
            title: "#{formula}: Formula version newer than livecheck",
            file:  formula.path.to_s.delete_prefix("#{repository}/"),
          )
        else
          opoo newer_than_upstream_msg
        end
      end

      def formula!(formula_name, args:)
        cleanup_during!(@testing_formulae, args: args)

        test_header(:Formulae, method: "formula!(#{formula_name})")

        formula = Formulary.factory(formula_name)
        if formula.disabled?
          skipped formula_name, "#{formula.full_name} has been disabled!"
          return
        end

        test "brew", "audit", "--strict", "--only=gcc_dependency", formula_name
        if steps.last.failed?
          skipped formula_name, "#{formula_name} should not have a Linux-only GCC dependency!"
          return
        end

        test "brew", "deps", "--tree", "--annotate", "--include-build", "--include-test", named_args: formula_name

        deps_without_compatible_bottles = formula.deps.map(&:to_formula)
        deps_without_compatible_bottles.reject! do |dep|
          bottled_or_built?(dep, @built_formulae - @skipped_or_failed_formulae)
        end
        bottled_on_current_version = bottled?(formula, no_older_versions: true)

        if deps_without_compatible_bottles.present? && !bottled_on_current_version
          message = <<~EOS
            #{formula_name} has dependencies without compatible bottles:
              #{deps_without_compatible_bottles * "\n  "}
          EOS
          skipped formula_name, message
          return
        end

        new_formula = @added_formulae.include?(formula_name)
        ignore_failures = !bottled_on_current_version && !new_formula

        deps = []
        reqs = []

        build_flag = if build_bottle?(formula, args: args)
          "--build-bottle"
        else
          if ENV["GITHUB_ACTIONS"].present?
            puts GitHub::Actions::Annotation.new(
              :warning,
              "#{formula} has unbottled dependencies, so a bottle will not be built.",
              title: "No bottle built for #{formula}!",
              file:  formula.path.to_s.delete_prefix("#{repository}/"),
            )
          else
            onoe "Not building a bottle for #{formula} because it has unbottled dependencies."
          end

          skipped formula_name, "No bottle built."
          return
        end

        # Online checks are a bit flaky and less useful for PRs that modify multiple formulae.
        skip_online_checks = args.skip_online_checks? || (@testing_formulae_count > 5)

        fetch_args = [formula_name]
        fetch_args << build_flag
        fetch_args << "--force" if args.cleanup?

        audit_args = [formula_name]
        audit_args << "--online" unless skip_online_checks
        if new_formula
          audit_args << "--new-formula"
        else
          audit_args << "--git" << "--skip-style"
        end

        # This needs to be done before any network operation.
        install_ca_certificates_if_needed

        if (messages = unsatisfied_requirements_messages(formula))
          test "brew", "fetch", "--retry", *fetch_args
          test "brew", "audit", *audit_args

          skipped formula_name, messages
          return
        end

        deps |= formula.deps.to_a.reject(&:optional?)
        reqs |= formula.requirements.to_a.reject(&:optional?)

        tap_needed_taps(deps)
        install_curl_if_needed(formula)
        install_mercurial_if_needed(deps, reqs)
        install_subversion_if_needed(deps, reqs)
        setup_formulae_deps_instances(formula, formula_name, args: args)

        test "brew", "uninstall", "--force", formula_name if formula.latest_version_installed?

        install_args = ["--verbose"]
        install_args << build_flag

        # Don't care about e.g. bottle failures for dependencies.
        test "brew", "install", "--only-dependencies", *install_args, formula_name,
             env: { "HOMEBREW_DEVELOPER" => nil }

        # Do this after installing dependencies to avoid skipping formulae
        # that build with and declare a dependency on GCC. See discussion at
        # https://github.com/Homebrew/homebrew-core/pull/86826
        install_gcc_if_needed(formula, deps)

        info_header "Starting tests for #{formula_name}"

        test "brew", "fetch", "--retry", *fetch_args

        env = {}
        env["HOMEBREW_GIT_PATH"] = nil if deps.any? do |d|
          d.name == "git" && (!d.test? || d.build?)
        end

        install_step_passed = formula_installed_from_bottle =
          install_previously_built_bottle?(formula) &&
          install_formula_from_bottle(formula_name,
                                      bottle_dir:                  @previously_built_bottle_cache,
                                      testing_formulae_dependents: false,
                                      dry_run:                     args.dry_run?)

        install_step_passed ||= begin
          test "brew", "install", *install_args,
               named_args:      formula_name,
               env:             env.merge({ "HOMEBREW_DEVELOPER" => nil }),
               ignore_failures: ignore_failures
          steps.last.passed?
        end

        livecheck(formula) if !args.skip_livecheck? && !skip_online_checks

        test "brew", "audit", *audit_args unless formula.deprecated?
        unless install_step_passed
          if ignore_failures
            skipped formula_name, "install failed"
          else
            failed formula_name, "install failed"
          end

          return
        end

        if formula_installed_from_bottle
          Pathname.pwd.install bottle_glob(formula_name,
                                           @previously_built_bottle_cache,
                                           ".{json,tar.gz}")
        else
          bottle_reinstall_formula(formula, new_formula, args: args)
        end
        test "brew", "linkage", "--test", named_args: formula_name, ignore_failures: ignore_failures
        failed_linkage_or_test_messages ||= []
        failed_linkage_or_test_messages << "linkage failed" unless steps.last.passed?

        if steps.last.passed?
          # Check for opportunistic linkage. Ignore failures because
          # they can be unavoidable but we still want to know about them.
          test "brew", "linkage", "--cached", "--test", "--strict",
               named_args:      formula_name,
               ignore_failures: true
        end

        test "brew", "linkage", "--cached", formula_name
        @linkage_output_path.write(Formatter.headline(steps.last.command_trimmed, color: :blue), mode: "a")
        @linkage_output_path.write("\n", mode: "a")
        @linkage_output_path.write(steps.last.output, mode: "a")

        test "brew", "install", "--only-dependencies", "--include-test", formula_name

        if formula.test_defined?
          env = {}
          env["HOMEBREW_GIT_PATH"] = nil if deps.any? do |d|
            d.name == "git" && (!d.build? || d.test?)
          end

          # Intentionally not passing --retry here to avoid papering over
          # flaky tests when a formula isn't being pulled in as a dependent.
          test "brew", "test", "--verbose", named_args: formula_name, env: env, ignore_failures: ignore_failures
          failed_linkage_or_test_messages << "test failed" unless steps.last.passed?
        end

        # Move bottle and don't test dependents if the formula linkage or test failed.
        if failed_linkage_or_test_messages.present?
          if @bottle_filename
            failed_dir = "#{File.dirname(@bottle_filename)}/failed"
            FileUtils.mkdir failed_dir unless File.directory? failed_dir
            FileUtils.mv [@bottle_filename, @bottle_json_filename], failed_dir
          end

          if ignore_failures
            skipped formula_name, failed_linkage_or_test_messages.join(", ")
          else
            failed formula_name, failed_linkage_or_test_messages.join(", ")
          end
        end
      ensure
        cleanup_bottle_etc_var(formula) if args.cleanup?

        test "brew", "uninstall", "--force", *@unchanged_dependencies if @unchanged_dependencies.present?
      end

      def deleted_formula!(formula_name)
        test_header(:Formulae, method: "deleted_formula!(#{formula_name})")

        test "brew", "uses",
             "--eval-all",
             "--include-build",
             "--include-optional",
             "--include-test",
             formula_name
      end

      def sorted_formulae
        changed_formulae_dependents = {}

        @testing_formulae.each do |formula|
          begin
            formula_dependencies =
              Utils.popen_read("brew", "deps", "--full-name",
                               "--include-build",
                               "--include-test", formula)
                   .split("\n")
            # deps can fail if deps are not tapped
            unless $CHILD_STATUS.success?
              Formulary.factory(formula).recursive_dependencies
              # If we haven't got a TapFormulaUnavailableError, then something else is broken
              raise "Failed to determine dependencies for '#{formula}'."
            end
          rescue TapFormulaUnavailableError => e
            raise if e.tap.installed?

            e.tap.clear_cache
            safe_system "brew", "tap", e.tap.name
            retry
          end

          unchanged_dependencies = formula_dependencies - @testing_formulae
          changed_dependencies = formula_dependencies - unchanged_dependencies
          changed_dependencies.each do |changed_formula|
            changed_formulae_dependents[changed_formula] ||= 0
            changed_formulae_dependents[changed_formula] += 1
          end
        end

        changed_formulae = changed_formulae_dependents.sort do |a1, a2|
          a2[1].to_i <=> a1[1].to_i
        end
        changed_formulae.map!(&:first)
        unchanged_formulae = @testing_formulae - changed_formulae
        changed_formulae + unchanged_formulae
      end
    end
  end
end
