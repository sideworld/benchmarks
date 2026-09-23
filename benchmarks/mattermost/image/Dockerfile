# The Mattermost server image, built from THIS source tree.
#
# Their own server/build/Dockerfile does not build from source: it curls a prebuilt release
# tarball (ARG MM_PACKAGE, default "latest stable enterprise") into a distroless base. That is
# right for shipping a release and useless for testing a pull request, because the pull request's
# code never enters the image. There is no `make build-image` target either — `make build` builds
# the Go binaries and the webapp bundle, and packaging is a separate step.
#
# So: take the published release image for v11.11.0 (client bundle, prepackaged plugins, config
# templates, mmctl, the document-processing utilities and the non-root `mattermost` user), and
# replace the two Go binaries with the ones compiled from this checkout by their own recipe,
# `make build-cmd-linux`. The result is their release layout running our server code.
#
# Build context: <repo>/server, after `make build-cmd-linux`.
ARG MM_RELEASE=11.11.0
FROM mattermost/mattermost-team-edition:${MM_RELEASE}
COPY --chown=2000:2000 bin/mattermost /mattermost/bin/mattermost
COPY --chown=2000:2000 bin/mmctl      /mattermost/bin/mmctl
