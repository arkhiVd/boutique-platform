/*
 * boutique-platform -- the root Jenkinsfile.
 *
 * WHAT THIS FILE IS RESPONSIBLE FOR
 * ---------------------------------------------------------------------------
 * Everything that has to be true before a change moves: the gates below run the
 * same commands scripts/check.sh runs on the laptop, each in a container pinned
 * in pipelines/vars/toolImages.groovy, so a green build means the same tools
 * agreed in both places rather than two people's environment agreeing by luck.
 *
 * WHAT IT DOES NOT DO
 * ---------------------------------------------------------------------------
 * This repository has no Dockerfile and deploys nothing of its own. The
 * image/deploy/smoke/canary/promote stages read parameters instead, and a run
 * that passes none of them records why each stage did nothing rather than
 * reporting a release that never happened. A service repository fills the same
 * parameters and gets the whole path: build, scan, deploy, smoke, canary with
 * automatic rollback, then a human approval before production.
 *
 * The library is loaded explicitly: JCasC sets globalLibraries to
 * implicit: false, which is what stops every job from silently depending on a
 * library whose name nobody wrote down.
 */
@Library('boutique-platform') _

pipeline {
    agent {
        // The pod template in ci/jenkins/values.yaml: jnlp runs the steps,
        // dind holds the docker daemon, serviceAccount jenkins-agent,
        // podRetention Never. Its own first label is release-dependent; `docker`
        // is the one this file pins.
        label 'docker'
    }

    options {
        // A build that outlives its usefulness holds an agent pod and the
        // namespace's quota with it. Thirty minutes is generous for a repo
        // whose gates are lint and policy; a service repo with a multi-arch
        // build raises it here, deliberately, rather than removing the timeout.
        timeout(time: 30, unit: 'MINUTES')
        disableConcurrentBuilds()
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '30'))
    }

    parameters {
        // ---- what this change builds -------------------------------------
        string(name: 'APP_IMAGE', defaultValue: '',
            description: 'Image ref to build and scan. Empty = this repository builds no image.')
        // ---- where it goes -----------------------------------------------
        string(name: 'APP_NAMESPACE', defaultValue: 'boutique',
            description: 'Namespace to deploy into (the RoleBinding in ci/rbac grants boutique only).')
        string(name: 'APP_MANIFESTS', defaultValue: '',
            description: 'Repo-relative directory of manifests to apply. Empty = deploy stage skipped.')
        string(name: 'APP_ROLLOUT', defaultValue: '',
            description: 'kind/name to set image on and wait for, e.g. deployment/frontend.')
        // ---- smoke gate ----------------------------------------------------
        string(name: 'APP_URL', defaultValue: '',
            description: 'Endpoint the smoke gate probes. Empty = smoke stage skipped.')
        // ---- canary gate ---------------------------------------------------
        string(name: 'APP_PROM_URL', defaultValue: '',
            description: 'Prometheus base URL the canary samples, e.g. http://prometheus.observability:9090.')
        string(name: 'APP_BURN_QUERY', defaultValue: '',
            description: 'PromQL the canary compares against the threshold (p99 latency, error ratio).')
        string(name: 'APP_BURN_THRESHOLD', defaultValue: '0',
            description: 'Breach when the sample is greater than this value.')
        string(name: 'APP_CANARY_DEPLOYMENT', defaultValue: '',
            description: 'Canary Deployment name -- rolled back automatically if the check breaches.')
        string(name: 'APP_TRAEFIK_SERVICE', defaultValue: '',
            description: 'traefik.io WeightedService object splitting traffic between the two services.')
        string(name: 'APP_STABLE_SERVICE', defaultValue: '',
            description: 'Service carrying the current release.')
        string(name: 'APP_CANARY_SERVICE', defaultValue: '',
            description: 'Service carrying the candidate.')
    }

    stages {
        stage('Build & test') {
            steps {
                script {
                    def images = toolImages()

                    // shellcheck's image is FROM scratch: no shell inside it to
                    // expand a glob, and no path in it except the one mount it
                    // gets. So the file list is computed here (in the agent,
                    // where the workspace is the workspace) and handed over as
                    // absolute paths under /work, where tools() mounts it.
                    String found = sh(
                        script: 'find scripts platform pipelines -name "*.sh" -not -path "*/.terraform/*" | sort',
                        returnStdout: true
                    ).trim()
                    List shellcheckFiles = found
                        ? found.split('\n').collect { "/work/${it}" }
                        : []

                    // kubeconform needs the same file set scripts/check.sh
                    // builds, exclusions included: chart inputs, vendored
                    // subcharts, Go template text and bare Prometheus rule files
                    // are not manifests, and a schema check on them reports a
                    // failure that has nothing to do with the cluster. If
                    // check.sh's exclusion set changes, this one changes with it.
                    String manifests = sh(
                        script: '''
                            find apps ci cluster observability -name '*.yaml' -not -path '*charts*' 2>/dev/null \
                            | grep -Ev '(values\\.yaml|Chart\\.ya?ml|Chart\\.lock)' \
                            | grep -Ev '(/rules/|/slos/|alerts\\.yaml$)' \
                            | grep -Ev '/templates/' \
                            | sort
                        ''',
                        returnStdout: true
                    ).trim()
                    List manifestFiles = manifests
                        ? manifests.split('\n').collect { "/work/${it}" }
                        : []
                    String crdSchemas = 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

                    // The conftest exclusion set, verbatim from scripts/check.sh:
                    // the upstream manifests and the policy's own tests, rules
                    // and templates are inputs to other checks, not subjects of
                    // this one.
                    String conftestIgnore = 'apps/boutique/(upstream-kubernetes-manifests\\.yaml|chaos/)|/templates/|(values\\.yaml|Chart\\.ya?ml|Chart\\.lock)$|/rules/|/slos/|alerts\\.yaml$'

                    List gates = [
                        [name : 'git: tip commit has no whitespace errors',
                         command: 'git log --check -1'],
                        [name : 'git: no merge conflict markers',
                         command: '''
                             if grep -rIl -e '^<<<<<<< ' -e '^>>>>>>> ' --exclude-dir=.git . 2>/dev/null | grep -q .; then
                                 echo 'conflict markers found in:'
                                 grep -rIl -e '^<<<<<<< ' -e '^>>>>>>> ' --exclude-dir=.git . 2>/dev/null || true
                                 exit 1
                             fi
                         '''],
                        [name : 'bash -n every shell script',
                         command: "find . -name '*.sh' -not -path './.git/*' -print0 | xargs -0 -r -n1 bash -n"],
                        [name : 'shellcheck (same files scripts/check.sh checks)',
                         image: images.shellcheck,
                         // The image's entrypoint IS shellcheck (it is built
                         // FROM scratch: one binary, no shell), so the command
                         // is its arguments -- naming the binary again would
                         // hand it a file called "shellcheck" to lint.
                         command: "-x ${shellcheckFiles.join(' ')}"],
                        [name : 'actionlint (every workflow)',
                         image: images.actionlint,
                         // No arguments on purpose: actionlint's arguments are
                         // file paths, and with none it searches
                         // .github/workflows itself -- which keeps a workflow
                         // added next week linted without editing this file.
                         command: ''],
                        [name : 'helm dependency build ci/jenkins',
                         image: images.helm,
                         // helm's entrypoint is the helm binary, so `repo add`
                         // and `dependency build` cannot be chained with &&
                         // inside the container: start a shell instead. The
                         // repo definition has to be created in the SAME
                         // container, because the cache it writes lives in
                         // HOME=/tmp, which is this container's and not the
                         // next one's.
                         dockerArgs: '--entrypoint /bin/sh',
                         command: "-c 'helm repo add jenkins https://charts.jenkins.io && helm dependency build ci/jenkins'"],
                        [name : 'helm lint --strict ci/jenkins',
                         image: images.helm,
                         command: 'lint --strict ci/jenkins'],
                        [name : 'helm template ci ci/jenkins',
                         image: images.helm,
                         command: 'template ci ci/jenkins >/dev/null'],
                        [name : 'conftest (apps cluster ci observability)',
                         image: images.conftest,
                         command: "test apps cluster ci observability -p policy --ignore '${conftestIgnore}'"],
                        [name : 'conftest rejects every should-fail fixture',
                         image: images.conftest,
                         // The fixture loop is shell, the conftest image's
                         // entrypoint is the conftest binary, and the two facts
                         // meet here: start the container with a shell instead.
                         dockerArgs: '--entrypoint /bin/sh',
                         command: "-c 'sh pipelines/resources/policy-fixtures.sh'"],
                        [name : 'kubeconform -strict (apps ci cluster observability)',
                         image: images.kubeconform,
                         command: '-strict -summary -kubernetes-version 1.36.3'
                             + ' -schema-location default'
                             + " -schema-location \"${crdSchemas}\""
                             + (manifestFiles ? " ${manifestFiles.join(' ')}" : '')],
                        [name : 'gitleaks (no secrets in the tree)',
                         image: images.gitleaks,
                         command: 'detect --no-git --source . --redact'],
                    ]

                    // push: false and a single platform on purpose: there is no
                    // registry in this account (no aws_ecr_repository exists --
                    // TASKS.md), so a build that tried to push would fail on
                    // credentials nobody has. buildAndTest rejects a multi-arch
                    // build without push: true, which is why platforms is not a
                    // parameter here either.
                    buildAndTest(
                        gates: gates,
                        image: params.APP_IMAGE ?: '',
                        push: false,
                        platforms: 'linux/amd64'
                    )
                }
            }
        }

        stage('Scan & sign') {
            steps {
                script {
                    // Unconditional: the manifest scan runs even when there is
                    // no image, because the manifests are the artifact this
                    // repository has.
                    scanAndSign(
                        manifests: 'ci',
                        image: params.APP_IMAGE ?: '',
                        // The vendored jenkins subchart, whose findings belong
                        // upstream, and ci/.trivyignore: the one finding in our
                        // own files that cannot be fixed without
                        // un-Jenkinsing Jenkins, with its reason written down.
                        trivySkipDirs: 'jenkins/charts',
                        trivyIgnorefile: 'ci/.trivyignore'
                    )
                }
            }
        }

        stage('Deploy to staging') {
            when {
                expression { params.APP_MANIFESTS || params.APP_ROLLOUT }
            }
            steps {
                script {
                    deployToStaging(
                        namespace: params.APP_NAMESPACE ?: 'boutique',
                        manifests: params.APP_MANIFESTS ?: '',
                        image: params.APP_IMAGE ?: '',
                        rollout: params.APP_ROLLOUT ?: ''
                    )
                }
            }
        }

        stage('Smoke gate') {
            when {
                expression { params.APP_URL }
            }
            steps {
                script {
                    smokeGate(
                        url: params.APP_URL,
                        namespace: params.APP_NAMESPACE ?: 'boutique'
                    )
                }
            }
        }

        stage('Canary') {
            when {
                // All or nothing: a canary that runs without a burn query, or
                // without the services to shift traffic between, would move
                // traffic and then be unable to say whether it was a mistake.
                expression {
                    params.APP_CANARY_DEPLOYMENT && params.APP_PROM_URL
                        && params.APP_BURN_QUERY && params.APP_TRAEFIK_SERVICE
                        && params.APP_STABLE_SERVICE && params.APP_CANARY_SERVICE
                }
            }
            steps {
                script {
                    canaryAndRollback(
                        namespace: params.APP_NAMESPACE ?: 'boutique',
                        deployment: params.APP_CANARY_DEPLOYMENT,
                        traefikService: params.APP_TRAEFIK_SERVICE,
                        stableService: params.APP_STABLE_SERVICE,
                        canaryService: params.APP_CANARY_SERVICE,
                        prometheusUrl: params.APP_PROM_URL,
                        burnQuery: params.APP_BURN_QUERY,
                        burnThreshold: params.APP_BURN_THRESHOLD ?: '0'
                    )
                }
            }
        }

        stage('Promote to production') {
            when {
                expression { params.APP_MANIFESTS || params.APP_ROLLOUT }
            }
            steps {
                script {
                    // The only blocking step in the pipeline. Denied = the run
                    // stops here, which is the difference between an approval
                    // gate and a notification.
                    promoteToProd(
                        namespace: params.APP_NAMESPACE ?: 'boutique',
                        manifests: params.APP_MANIFESTS ?: '',
                        rollout: params.APP_ROLLOUT ?: '',
                        image: params.APP_IMAGE ?: '',
                        reason: "Build #${env.BUILD_NUMBER} passed every gate. Promote to production?"
                    )
                }
            }
        }
    }

    post {
        always {
            // Written by scanAndSign only when an image was built;
            // allowEmptyArchive keeps its absence from failing a run that had
            // no image to scan.
            archiveArtifacts artifacts: 'sbom.cdx.json', allowEmptyArchive: true
        }
    }
}
