from spack.package import *
from spack.pkg.builtin.w3emc import W3emc as BuiltinW3emc

class W3emc(BuiltinW3emc):
    # Method A: Git Checkout (Recommended)
    # Spack clones the repo and checks out this specific commit.
    git = "https://github.com/NOAA-EMC/NCEPLIBS-w3emc"
    
    # You only need the commit hash here:
    version("module-test", commit="d923949dc98e85f440698c3a79b57aff6302fec6")
