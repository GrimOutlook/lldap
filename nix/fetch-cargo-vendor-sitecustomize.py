# Reimplements nixpkgs' own sitecustomize.py (which resolves NIX_PYTHONPATH
# into sys.path so `requests` etc. become importable) and layers a UA-setting
# patch on top. This has to fully replace, not supplement, the real
# sitecustomize.py: Python's site module imports only the first module named
# "sitecustomize" found on sys.path, and PYTHONPATH entries are always
# searched before the interpreter's own site-packages -- so pointing
# PYTHONPATH at a directory containing our own sitecustomize.py shadows the
# real one entirely, breaking every import that depends on it.
#
# The UA patch itself works around crates.io returning 403 for requests'
# default "python-requests/x.y" User-Agent (undocumented crates.io policy),
# which otherwise breaks rustPlatform.fetchCargoVendor for any crate whose
# fetch is retried past the local disk cache.
import site
import sys
import os
import functools

paths = os.environ.pop('NIX_PYTHONPATH', None)
if paths:
    functools.reduce(lambda k, p: site.addsitedir(p, k), paths.split(':'), site._init_pathinfo())

in_venv = (sys.version_info.major == 3 and sys.prefix != sys.base_prefix)
if not in_venv:
    executable = os.environ.pop('NIX_PYTHONEXECUTABLE', None)
    prefix = os.environ.pop('NIX_PYTHONPREFIX', None)
    if 'PYTHONEXECUTABLE' not in os.environ and executable is not None:
        sys.executable = executable
    if prefix is not None:
        sys.prefix = sys.exec_prefix = prefix
        site.PREFIXES.insert(0, prefix)

import requests
_orig_init = requests.Session.__init__
def _patched_init(self, *a, **kw):
    _orig_init(self, *a, **kw)
    self.headers.update({"User-Agent": "lldap-nix-build (dominic.j.grimaldi@gmail.com)"})
requests.Session.__init__ = _patched_init
