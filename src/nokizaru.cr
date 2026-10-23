require "./nokizaru/cli"

# Entrypoint for the Nokizaru binary: parse argv and run the CLI, exiting with
# its status. Specs require the individual source files, never this root, so the
# dispatch below runs only for the built binary, not under `crystal spec`.
exit Nokizaru::CLI.start(ARGV)
