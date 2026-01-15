from spack.package import *
from spack.pkg.builtin.w3emc import W3emc as BuiltinW3emc

class W3emc(BuiltinW3emc):
    # Method A: Git Checkout (Recommended)
    # Spack clones the repo and checks out this specific commit.
    git = "https://github.com/AlexanderRichert-NOAA/NCEPLIBS-w3emc"
    
    # You only need the commit hash here:
    version("add_module", commit="035a2a2e3356ad469c68c9edf659f89416417fe2")
