# Victor's Homelab Playbook


This playbook configures victor's personal homelab using ansible.

- [Getting Started](#getting-started)
  - [Prerequisities](#prerequisities)
  - [Installing](#installing)
- [Usage](#usage)
- [Testing](#testing)
- [Built With](#built-with)
- [Versioning](#versioning)
- [Authors](#authors)
- [License](#license)
- [Contributing](#contributing)

## Getting Started

The Foundryvtt playbook multiple roles. You can check the [requirements](requirements.yml) to see dependencies versions.

### Prerequisities

Ansible 2.17.5 version installed. You can use the installed version in your virtual env (see Testing).

Inventory destination should be a Debian (Bullseye at least) environment.

For testing purposes, [Molecule](https://molecule.readthedocs.io/en/latest/) with [Goss](https://goss.rocks) as verifier and [Docker](https://docker.com/) as provider.

Docker 26.0.0 CE version recommended (but sure you can run previous releases) for testing in your local environment.

### Installing

See [Testing](#testing) :)

## Usage

To run the playbook from scratch run [provision.sh](scripts/provision.sh) script.

Look to the defaults properties file of each role used.

Also the tests of each role can give you clues of usages.


## Testing

### Ansible and Molecule

You have to install pip3 and pipenv so you can run:
```
$ sudo apt install python3-pip
$ pip3 install --user pipenv
```

```
$ pipenv sync
$ pipenv run molecule -c molecule/molecule.yml test
```
Note: these tests need opening Ansible vaults. This requirement can be accomplished adding a .pass.txt file into the directory of the molecule scenario. Another option is running molecule with a environment variable VAULT_PASSWORD=mysupersecretpassword.

Tip: if you get in a mess installing dependencies with pipenv, you can remove the virtualenv running this command at the same path:
```
$ pipenv --rm
```
After it you can create a fresh virtualenv again.

### Docker

To install Docker, follow the steps covered in the [official guide](https://docs.docker.com/install/). If you're ok with the implications, [manage Docker as a non-root user](https://docs.docker.com/install/linux/linux-postinstall/#manage-docker-as-a-non-root-user) will make things easier to use it.

If you need to access the container(s), use `molecule login` command, which its flags and parameters are documented [here](https://molecule.readthedocs.io/en/2.20/usage.html#login)

### Tests with Goss

If you want to add or modify the tests in `molecule/default/tests/test_*.yml`, see the [documentation](https://github.com/aelsabbahy/goss/blob/master/docs/manual.md).

## Built With

![Ansible](https://img.shields.io/badge/ansible-2.7.0-green.svg)

## Versioning

Additionaly you can see what change in each version in the [CHANGELOG.md](CHANGELOG.md) file.

## Authors

* **Idealista** - *Work with* - [idealista](https://github.com/idealista)
