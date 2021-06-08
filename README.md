# helm-adopt-package-history

⚠️ This tool helps with one possible resolution to the `stable` and `incubator` charts repo package history garbage collection planned for Nov 2020. Keep an eye out for forthcoming updates on the [Helm Blog](https://helm.sh/blog/).

## Install

This may become a helm plugin if there's a need for it.
Quick and dirty install for now.
Will add a more reasonable installation method one way or another.
This is a work in progress 🤓

```console
git clone git@github.com:scottrigby/helm-adopt-package-history.git ~/somewhere/helm-adopt-package-history
ls -s ~/somewhere/helm-adopt-package-history/helm-adopt-package-history.sh /usr/local/bin/helm-adopt-package-history
```

## Usage

`helm-adopt-package-history --help`

```text
This comand helps a distributed chart repo adopt another repo's package history

The goal is to make it easy for distributed Chart repo maintainers who have
already adopted helm charts to also store chart version packages prior to
adoption.

Scope: because distributed chart repo index and packages may be hosted
in various ways (object storage, GitHub pages, or any other HTTP server), this
command only helps find and download the package history of charts you have
already adopted, and updates your local repo directory for manual review. It
does not perform any commits or attempt to upload to your chart repository.

Context for stable/incubator: If adopting from stable or incubator repos, as of
13 November 2020, these will be deprecated and the Google sponsored GCP storage
buckets will be garbage collected. Due to global download usage, the cost of
these buckets is too high to move package history all together to new single
storage location. Instead, the Helm team is promoting the strategy for adopting
distributed chart repos to also host package history for the their adopted
charts, spreading the load in a more maintainable way. For updates on stable
chart adoption progress, see https://github.com/helm/charts/issues/21103.

Requires:
    helm >= 3.3.4
    yq 3.x

Usage:
    helm-adopt-package-history [flags]

Flags:
    -o, --old-repo
        Old chart repo (example: stable=https://kubernetes-charts.storage.googleapis.com)
    -n, --new-repo
        New chart repo (example: foo=http://charts.foo.bar)
    -l, --local-dir
        Local directory containing chart repo index file and packages
    -i, --include-charts
        Optional. Comma-separated list of charts to include (default: all charts listed in new repo index)
    -e, --exclude-charts
        Optional. Comma-separated list of charts to exclude (defult: none)
    -s, --skip-repo-commands
        Optional. Skips 'helm repo add' and 'helm repo update' commands
    -f, --force-update
        Optional. Passes '--force-update' option to 'helm repo add'
    -h, --help
        help message
```

## Example

This is a walkthrough of the tool, using the [Jenkins Community Kubernetes Helm Charts](https://github.com/jenkinsci/helm-charts) as an example, to show how to host `stable` package history prior to chart repo adoption.

Because the `jenkinsci` chart repo is hosted on GitHub Pages, we will first need to check out the `gh-pages` branch before running the helper command, so that the charts repo local directory contains at minimum the `index.yaml` file. Chart repos hosted in a different way will need to adjust these instructions (see [usage](#usage) above).

```console
$ local_dir=$HOME/code/github.com/jenkinsci/helm-charts
$ mkdir -p $local_dir
$ git clone --branch gh-pages git@github.com:jenkinsci/helm-charts.git $local_dir

# Ensure the index file is present
$ ls $local_dir/index.yaml
index.yaml
```

Run the command:

```console
$ helm-adopt-package-history \
    --old-repo=stable=https://kubernetes-charts.storage.googleapis.com \
    --new-repo=jenkinsci=https://charts.jenkins.io \
    --local-dir=$HOME/code/github.com/jenkinsci/helm-charts
Attempting package history download from stable, for charts:
     1 jenkins
To temp directory: /var/folders/p2/d06q9v3s4jz83bjnt60xt03h0000gn/T/tmp.jqK4RntF
⏳ downloading packages for stable/jenkins (1 of 1). package 0.37.1 (148 of 294)
✅ downloaded 294 packages for stable/jenkins
✅ updated local index
✅ moved package history to local dir
Reminder to manually review your local repo directory before pushing to your repo
See 'helm-adopt-package-history --help' for goal, scope and context
Thanks for contributing 🙂
```

As the reminder output says, we'll need to manually review the updated local index and downloaded package history in the local repo.

```console
$ cd $local_dir

$ git status -s | head
 M index.yaml
?? jenkins-0.1.0.tgz
?? jenkins-0.1.1.tgz
?? jenkins-0.1.10.tgz
?? jenkins-0.1.12.tgz
?? jenkins-0.1.13.tgz
?? jenkins-0.1.14.tgz
?? jenkins-0.1.15.tgz
?? jenkins-0.1.4.tgz
?? jenkins-0.1.5.tgz

# Just for fun
$ ls jenkins-*.tgz | wc -l
     294
```

In this example, after inspecting the `index.yaml` diff, and a quick review of the package list, we're satisfied.
Again, if your charts repo is hosted in another way – for example, the index file in one location, and the packages in another, you will want to follow your process accordingly.
Seriously, please see [usage](#usage) above, this is just one example for how charts repos can be hosted.

Ensure you've [forked](https://docs.github.com/en/free-pro-team@latest/github/getting-started-with-github/fork-a-repo) the upstream repo (either manually or using the CLI). Let's assume your fork remote is called `your-username`. If you contribute to multiple chart repos, you will want to [rename](https://docs.github.com/en/free-pro-team@latest/github/administering-a-repository/renaming-a-repository) your fork acordingly. It will probably look something like this:

```console
$ git remote -v
jenkinsci       git@github.com:jenkinsci/helm-charts.git (fetch)
jenkinsci       git@github.com:jenkinsci/helm-charts.git (push)
your-username   git@github.com:your-username/jenkinsci-helm-charts.git (fetch)
your-username   git@github.com:your-username/jenkinsci-helm-charts.git (push)
```

Since the repo is hosted on GitHub Pages, to contribute this change, we'll want to checkout a new local branch from the `gh-pages` base branch, add our manually reviewed files, and issue a [Pull Request](https://docs.github.com/en/free-pro-team@latest/github/collaborating-with-issues-and-pull-requests/creating-a-pull-request) against the upstream remote base branch.
You can make a PR using the [GitHub CLI](https://github.com/cli/cli), or however you like.
Be sure to add some context to your PR – you can feel free to link to this repo if that makes it easier.
For example:

```console
$ git checkout -b package-history
$ git add index.yaml jenkins-*.tgz
$ git commit -m --signoff "[jenkins] Add package history prior to chart repo adoption"
$ git push your-username package-history

# Using GitHub CLI
$ gh pr create --base gh-pages --head YOUR_USER:package-history --body 'See https://github.com/scottrigby/helm-adopt-package-history' --web
```

After the PR is merged, and the repo index is update is live, end users will be able to install all previous package versions by changing their commands from `helm install stable/jenkins --version x.y.z` to `helm install jenkinsci/jenkins --version x.y.z`, just as they must already do for newer releases after the chart was `deprecated` in `stable` and adopted by `jenkinsci`.
