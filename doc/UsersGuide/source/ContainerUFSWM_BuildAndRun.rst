.. _container-rt-tests:

******************************************************
Use of Software Containers for the UFS Weather Model
******************************************************

This chapter describes how to build and run the UFS Weather Model (:term:`WM`) using
Singularity/Apptainer software containers that bundle the prerequisite software libraries
and packages for the UFS WM, including compilers, MPI, and all required third-party
libraries. The UFS Weather Model source code and its submodules are checked out from the
standard GitHub repositories and built inside the container environment, eliminating the
need to install :term:`spack-stack` or host-specific modules.

The Regression Test (:term:`RT`) framework is adopted as a convenient starting point to
help users familiarize themselves with the UFS WM and to provide a simple build-and-run
workflow. Users may need to modify the configuration to suit their computing platform
standards and job scheduler (if any), and to adjust the locations of staged input data,
the container image, and the runtime directory, as well as host-system modules. Users are
encouraged to further tailor the containerized RT workflow to fit their own modeling needs
beyond running pre-defined test cases.

The workflow uses a standalone driver script, ``tests/rt_container.sh``, and a companion
configuration file, ``tests/rt_container.conf``. The driver compiles the model inside the
container and then runs each listed test sequentially, waiting for each job to complete
before starting the next. No Rocoto or ECFlow workflow manager is involved.

.. attention::

   This chapter applies **only** to the container-based workflow driven by ``rt_container.sh``.
   For the standard (non-container) RT framework driven by ``rt.sh``, see
   :numref:`Section %s <UsingRegressionTest>`.

.. _container-rt-prereqs:

=============
Prerequisites
=============

.. _container-rt-apptainer:

Singularity/Apptainer
-----------------------

Users must have **Singularity** or **Apptainer** installed on their compute platform. On many HPC systems, Singularity/Apptainer is available as a loadable module:

.. code-block:: console

   module load singularity
   # or
   module load apptainer

When not available system-wide, Apptainer can be installed on a Linux-based system by following the `Apptainer Installation Guide <https://apptainer.org/docs/admin/latest/installation.html>`__.

The following table lists the container software and the module load command on NOAA RDHPC Tier 1 platforms:

.. list-table:: Container software on NOAA RDHPC Tier 1 platforms
   :widths: 25 25 30
   :header-rows: 1

   * - Machine
     - Container command
     - Module to load
   * - Ursa
     - ``apptainer``
     - none required
   * - Gaea-C6
     - ``apptainer``
     - none required
   * - Hercules / Orion
     - ``singularity``
     - ``module load singularity``
   * - Derecho
     - ``apptainer``
     - ``module load apptainer``
   * - NOAA Cloud (AWS/Azure)
     - ``singularity``
     - none required

.. note::

   Apptainer is fully compatible with Singularity, and commands shown with ``singularity`` may be replaced with ``apptainer`` as appropriate.
   When using Apptainer, prefer the ``APPTAINER_`` environment-variable prefix
   instead of the legacy ``SINGULARITY_`` prefix.

Further information on Singularity/Apptainer is available at:

- `Apptainer documentation <https://apptainer.org/docs/>`__
- `SingularityCE documentation <https://docs.sylabs.io/guides/latest/user-guide/>`__
- `NOAA RDHPCS container documentation <https://docs.rdhpcs.noaa.gov/software/containers>`__

.. _container-rt-image:

Container Image
---------------

The container RT workflow requires a pre-built software-stack Singularity/Apptainer image (``*.sif``). Both GNU-based and Intel-based images are supported.

.. note::

   The method for accessing pre-staged container images on NOAA RDHPC Tier 1 platforms and
   for building containers from Docker Hub on other community platforms is identical to the
   procedure described in the `UFS Short-Range Weather (SRW) App Container Quick Start Guide
   <https://ufs-srweather-app.readthedocs.io/en/latest/BuildingRunningTesting/ContainerQuickstart.html>`__.
   Users already familiar with SRW App containers may refer to that guide for additional
   context, troubleshooting tips, and platform-specific notes.

.. _container-rt-image-tier1:

On NOAA RDHPC Tier 1 Platforms
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Pre-built images for both GNU and Intel toolchains are staged at system-specific shared directories:

.. list-table:: Pre-built container image locations on Tier 1 platforms
   :widths: 20 50
   :header-rows: 1

   * - Machine
     - Directory
   * - Ursa
     - ``/scratch3/NCEPDEV/nems/role.epic/containers``
   * - Gaea-C6
     - ``/gpfs/f6/bil-fire8/world-shared/containers``
   * - Hercules / Orion
     - ``/work/noaa/epic/role-epic/contrib/containers``
   * - Derecho
     - ``/glade/work/epicufsrt/contrib/containers``
   * - NOAA Cloud
     - ``/contrib/EPIC/containers``

The container image file names are:

.. list-table:: Container image file names
   :widths: 15 25 40
   :header-rows: 1

   * - Toolchain
     - Platform
     - Image file name
   * - GNU (GCC 13.3.1 / OpenMPI 4.1.6)
     - Ursa, Gaea-C6, Hercules, Orion, NOAA Cloud
     - ``rocky9-gcc13-ss192-ompi416.sif``
   * - GNU (GCC 13.3.1 / OpenMPI 5.0.7)
     - Derecho
     - ``rocky9-gcc13-ss192-ompi507.sif``
   * - Intel (oneAPI 2024.2 / Intel MPI 2021.13)
     - Ursa, Gaea-C6, Hercules, Orion, NOAA Cloud
     - ``rocky9-oneapi2024.2-ss192.sif``

.. note::

   Derecho uses a GNU container image built with **OpenMPI 5.0.7** (``ompi507``) rather
   than 4.1.6 (``ompi416``) used on other platforms, due to MPI compatibility requirements
   on that system. The Intel container image has **not** been tested on Derecho to date;
   only the GNU container is currently supported there.

For example, on Hercules or Orion the Intel image is at:

.. code-block:: console

   /work/noaa/epic/role-epic/contrib/containers/rocky9-oneapi2024.2-ss192.sif

Set an environment variable for convenience:

.. code-block:: console

   # GNU image (Hercules, Orion, Ursa, Gaea-C6, NOAA Cloud)
   export CONTAINER_IMG=<container-dir>/rocky9-gcc13-ss192-ompi416.sif
   # GNU image (Derecho — OpenMPI 5.0.7)
   export CONTAINER_IMG=<container-dir>/rocky9-gcc13-ss192-ompi507.sif
   # Intel image (Hercules, Orion, Ursa, Gaea-C6, NOAA Cloud)
   export CONTAINER_IMG=<container-dir>/rocky9-oneapi2024.2-ss192.sif

.. _container-rt-image-build:

Building a Container Image on Other Systems
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

On systems where a pre-staged image is not available, build a Singularity/Apptainer image from Docker Hub.

.. note::

   Building a container image or sandbox requires temporary disk space in ``/tmp`` or ``~/.singularity/cache``.
   On systems with limited home-directory space, redirect the cache and temp directories before building:

   .. code-block:: console

      export SINGULARITY_CACHEDIR=/path/to/large/filesystem/cache
      export SINGULARITY_TMPDIR=/path/to/large/filesystem/tmp

   When using Apptainer, use ``APPTAINER_CACHEDIR`` and ``APPTAINER_TMPDIR`` instead.

**Option 1: Build a GNU-based container from Docker Hub**

On most platforms (Ursa, Gaea-C6, Hercules, Orion, NOAA Cloud):

.. code-block:: console

   singularity build rocky9-gcc13-ss192-ompi416.sif \
       docker://noaaepic/rocky9-gcc13.3.1-spack-stack:v1.9.2-ufs-env-ompi416

   export CONTAINER_IMG=${PWD}/rocky9-gcc13-ss192-ompi416.sif

On **Derecho**, use the OpenMPI 5.0.7 variant instead:

.. code-block:: console

   singularity build rocky9-gcc13-ss192-ompi507.sif \
       docker://noaaepic/rocky9-gcc13.3.1-spack-stack:v1.9.2-ufs-env-ompi507

   export CONTAINER_IMG=${PWD}/rocky9-gcc13-ss192-ompi507.sif

**Option 2: Build an Intel-capable container from Docker Hub**

The Intel oneAPI software cannot be distributed inside Docker Hub images due to Intel's End User License Agreement (EULA). An Intel-capable software-stack image is available on Docker Hub, but the Intel oneAPI compilers and MPI must be reinstalled locally into a writable sandbox. The steps below produce a fully functional Intel image.

.. note::

   Site-specific SingularityCE installations may restrict sandbox builds more than Apptainer.
   If you encounter errors with SingularityCE, use Apptainer for the build steps and
   SingularityCE for runtime afterwards. On Hercules/Orion, a build-capable Apptainer
   is available via:

   .. code-block:: console

      module load spack-managed-x86-64_v3/v1.0 apptainer/1.3.3

#. Create a writable sandbox from the Docker Hub Intel-capable image. Bind all host
   top-level filesystems that contain your working directories (replace ``</top_dir>``
   and optional ``</bind_add>`` with paths appropriate for your system — see
   :numref:`Section %s <container-rt-binddirs>`):

   .. code-block:: console

      singularity build -B </top_dir> [-B </bind_add>] --sandbox --fix-perms \
          rocky9-oneapi2024.2-ss192 \
          docker://noaaepic/rocky9-oneapi2024.2-spack-stack:v1.9.2-ufs-wm-env

#. Copy the helper scripts out of the sandbox:

   .. code-block:: console

      singularity exec rocky9-oneapi2024.2-ss192 cp /opt/*.sh .

   The scripts ``intel-sandbox.sh`` and ``compilers_cp.sh`` retrieve and reinstall the
   Intel compiler and MPI components.

#. Create the Intel oneAPI source sandbox:

   .. code-block:: console

      ./intel-sandbox.sh

   This produces an additional ``intel-sandbox`` directory containing the Intel oneAPI
   compilers and MPI.

#. Copy the Intel compilers and MPI into the software-stack sandbox. Provide only the
   sandbox names (not full paths):

   .. code-block:: console

      ./compilers_cp.sh intel-sandbox rocky9-oneapi2024.2-ss192

   After this step, the software-stack sandbox contains the full Intel toolchain.
   The ``intel-sandbox`` directory can then be removed.

#. Convert the sandbox into a compressed SIF image:

   .. code-block:: console

      singularity build -B </top-level-dir> --fix-perms \
          rocky9-oneapi2024.2-ss192.sif rocky9-oneapi2024.2-ss192

      export CONTAINER_IMG=${PWD}/rocky9-oneapi2024.2-ss192.sif

.. _container-rt-binddirs:

Bind Directories for Tier 1 Platforms
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The following table lists the typical bind directories for NOAA RDHPC Tier 1 platforms.
These paths should be provided as a comma-separated list in the ``BIND_DIRS`` field of
``rt_container.conf`` header line 1 (see :numref:`Section %s <container-rt-conf>`):

.. list-table:: Typical bind directories on NOAA RDHPC Tier 1 platforms
   :widths: 25 35 40
   :header-rows: 1

   * - Machine
     - Main bind directory
     - Additional bind directory
   * - Derecho
     - ``/glade``
     - none
   * - Ursa
     - ``/scratch3``
     - ``/scratch4``
   * - Gaea-C6
     - ``/gpfs``
     - ``/ncrc/home2``
   * - Hercules / Orion
     - ``/work``
     - ``/work2``, ``/local``
   * - NOAA Cloud (AWS/Azure)
     - ``/contrib``
     - ``/lustre``

.. _container-rt-data:

Input and Baseline Data
-----------------------

The container RT workflow uses the same input datasets as the standard RT framework. On Level 1 and Level 2 systems these are pre-staged; see :numref:`Section %s <DataLocations>` for the ``DISKNM`` and ``INPUTDATA_ROOT`` paths for each platform. These paths are set in ``rt_container.conf`` (see :numref:`Section %s <container-rt-conf>`).

For Level 3–4 systems, input data is publicly available in the `UFS WM Data Bucket <https://registry.opendata.aws/noaa-ufs-regtests/>`__.

.. _container-rt-setup:

==================
Repository Setup
==================

Clone the UFS Weather Model repository and its submodules:

.. code-block:: console

   git clone --recursive https://github.com/ufs-community/ufs-weather-model.git
   cd ufs-weather-model

All further steps in this section assume the working directory is the root of the cloned repository.

.. _container-rt-modulefiles:

Required Modulefiles
--------------------

Two Lmod modulefiles must be created in ``modulefiles/`` before running the container RT tests. These files are not shipped with the repository because they are specific to the container image and host platform.

.. _container-rt-runtime-mod:

``ufs_container.runtime.lua`` — Host-Side Runtime Module
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

This modulefile is loaded **on the host** by ``rt_container.sh`` and by the compile and run job cards. Its purpose is to make the ``apptainer`` or ``singularity`` command and the host MPI libraries available in the job environment.

A minimal example for Hercules or Orion, where only the Singularity module needs to be loaded:

.. code-block:: lua

   -- modulefiles/ufs_container.runtime.lua
   -- Host-side runtime environment for container-based UFS-WM RTs (Hercules/Orion)
   whatis("Host runtime module: loads singularity for container RT jobs")

   load("singularity")

On Derecho, Apptainer is a loadable module and must be accompanied by the host GNU compiler
and OpenMPI that match the container image:

.. code-block:: lua

   -- modulefiles/ufs_container.runtime.lua
   -- Host-side runtime environment for container-based UFS-WM RTs (Derecho)
   whatis("Host runtime module: loads apptainer, GNU compilers, and host OpenMPI for container RT jobs")

   load("apptainer")
   load("gcc/14.3.0")
   load("openmpi/5.0.9")

Adapt the module names to match the target platform. On platforms where
Singularity/Apptainer is already in ``PATH`` (e.g., Gaea-C6, NOAA Cloud), this file
may be left empty or only load supplementary host libraries needed by the MPI launcher.

.. _container-rt-build-mod:

``ufs_container.<compiler>.lua`` — Inside-Container Build Module
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

This modulefile is loaded **inside the container** during both the compile and the run stages. It sets up the compiler toolchain, MPI library, and all required software libraries available within the container image.

A minimal example for an Intel-based container image:

.. code-block:: lua

   -- modulefiles/ufs_container.intel.lua
   -- Inside-container build/run environment for Intel-based UFS-WM container
   whatis("Inside-container software environment: Intel compilers, MPI, and spack-stack libraries")

   -- The container image ships with a self-contained module system.
   -- Adjust paths to match the software stack inside the image.
   prepend_path("MODULEPATH", "/opt/spack-stack/envs/ufs-wm/install/modulefiles/Core")

   load("stack-intel/2024.2.1")
   load("stack-intel-oneapi-mpi/2021.13")
   load("ufs-weather-model-env")

The exact module names depend on the container image being used. To discover available
modules, open an interactive shell inside the container (example for the Intel-based
container on Hercules/Orion):

.. code-block:: console

   singularity shell -B /work -B /work2 -B /local ${CONTAINER_IMG}
   # inside the container:
   source /opt/spack-stack/spack-stack-1.9.2/.bashenv   # or equivalent init script
   module avail
   module load stack-oneapi/2024.2.1
   module load stack-intel-oneapi-mpi/2021.13
   module avail

.. note::

   If ``modulefiles/ufs_container.<compiler>.lua`` is not present, the RT driver falls back to
   ``tests/modules.fv3_<compile_id>.lua`` if one exists for the specific compile configuration.
   Providing the shared ``ufs_container.<compiler>.lua`` modulefile is the recommended approach
   when one software stack covers all compile configurations.

.. _container-rt-conf:

====================================
Configuring ``rt_container.conf``
====================================

The file ``tests/rt_container.conf`` controls what gets compiled and tested. It begins with five mandatory header lines followed by one or more compile configuration blocks, each with a list of test cases.

The file uses ``|`` as a field separator and ``#`` for comments. Blank lines between configuration blocks are ignored.

.. code-block:: text

   # tests/rt_container.conf — example configuration

   # Header line 1: RT_COMPILER | CONTAINER_IMG | BIND_DIRS
   intel | /work/noaa/epic/role-epic/contrib/containers/rocky9-oneapi2024.2-ss192.sif | /work,/work2,/local

   # Header line 2: TPN | SCHEDULER | ACCNR | PARTITION | QUEUE | MPI_LAUNCH
   80 | slurm | epic | hercules | batch |

   # Header line 3: DISKNM
   /work2/noaa/epic/hercules/UFS-WM_RT

   # Header line 4: INPUTDATA_ROOT
   /work2/noaa/epic/hercules/UFS-WM_RT/NEMSfv3gfs/input-data-20251015

   # Header line 5: RUNDIR_ROOT
   /work2/noaa/epic/nperlin/hercules/UFS-WM/ufs-weather-model/tests/run_container

   # Compile configuration block: compile_id | MAKE_OPT
   atm | -DAPP=ATM -DCCPP_SUITES=FV3_GFS_v16,FV3_GFS_v17_p8
   control_c48
   control_p8

Header Line Fields
------------------

**Header line 1:**

.. list-table::
   :widths: 20 60
   :header-rows: 1

   * - Field
     - Description
   * - ``RT_COMPILER``
     - Compiler toolchain used inside the container: ``intel`` or ``gnu``.
   * - ``CONTAINER_IMG``
     - Absolute path to the Singularity/Apptainer image file (``*.sif``) on the host.
   * - ``BIND_DIRS``
     - Comma-separated list of host directories to bind-mount into the container.
       Include all filesystems containing the source tree, input data, and run directory.
       See :numref:`Section %s <container-rt-binddirs>` for typical values on Tier 1 platforms.

**Header line 2:**

.. list-table::
   :widths: 20 60
   :header-rows: 1

   * - Field
     - Description
   * - ``TPN``
     - MPI tasks per node (default: 40).
   * - ``SCHEDULER``
     - Job scheduler: ``slurm``, ``pbs``, or ``none`` for interactive single-node runs.
   * - ``ACCNR``
     - Scheduler account or project name (leave blank if not required).
   * - ``PARTITION``
     - Slurm partition name (leave blank for PBS or interactive runs).
   * - ``QUEUE``
     - Slurm QOS / PBS queue name (leave blank for interactive runs).
   * - ``MPI_LAUNCH``
     - MPI launch command used when ``SCHEDULER=none``: ``mpirun`` or ``mpiexec``.
       Defaults to ``mpirun`` if omitted.

**Header lines 3–5:** One filesystem path per line:

.. list-table::
   :widths: 20 60
   :header-rows: 1

   * - Line
     - Description
   * - ``DISKNM``
     - Top-level RT data directory; also used as the baseline comparison root.
   * - ``INPUTDATA_ROOT``
     - Input data directory (typically ``${DISKNM}/NEMSfv3gfs/input-data-<date>``).
   * - ``RUNDIR_ROOT``
     - Top-level directory where compile and test run directories will be created.
       This should be a user-writable path outside the source tree (e.g., on a
       scratch or work filesystem). If ``RUNDIR_ROOT`` differs from
       ``${PATHRT}/run_dir``, the driver automatically creates a convenience
       symlink ``tests/run_dir`` pointing to ``RUNDIR_ROOT``.

Compile Configuration Blocks
-----------------------------

After the five header lines, each compile configuration block consists of:

1. A **compile line** containing the configuration name and CMake options, separated by ``|``:

   .. code-block:: text

      <compile_id> | <MAKE_OPT>

2. One or more **test case lines**, each naming a single test (no ``|`` character):

   .. code-block:: text

      <test_case_name>

A blank line between blocks closes the current configuration. Configuration names must be unique. CMake options follow the same conventions as the standard ``rt.conf`` file.

.. note::

   The workflow is **sequential**: the driver compiles configuration 1, runs all its tests in order,
   then moves to configuration 2, and so on. A startup summary listing all configurations and their
   test cases is printed before any work begins.

.. _container-rt-run:

====================
Running the Tests
====================

All tests are launched by running ``rt_container.sh`` from the ``tests/`` directory:

.. code-block:: console

   cd tests
   ./rt_container.sh [options] [rt_container.conf]

If no configuration file is specified, ``tests/rt_container.conf`` is used by default.

Command-Line Options
--------------------

.. list-table::
   :widths: 10 60
   :header-rows: 1

   * - Option
     - Description
   * - ``-d``
     - Delete each test run directory after the test completes.
   * - ``-l <file>``
     - Use ``<file>`` as the configuration file instead of the default.
   * - ``-n <name>``
     - Run only the single test named ``<name>`` (the compile step that owns it still runs).
   * - ``-o``
     - Compile only; skip all test cases.
   * - ``-v``
     - Verbose output: enables shell tracing (``set -x``) in the driver and all sub-scripts,
       prints full configuration detail on startup, and prompts before starting work.
   * - ``-h``
     - Print help and exit.

Job Script Templates
--------------------

Before running, users should review the job script templates in ``tests/fv3_conf/`` to
ensure they are appropriate for their system:

- ``fv3_slurm.IN_container`` — Slurm run job card
- ``fv3_qsub.IN_container`` — PBS run job card
- ``compile_slurm.IN_container`` — Slurm compile job card
- ``compile_qsub.IN_container`` — PBS compile job card

These templates contain scheduler directives and environment setup that may require
platform-specific adjustments. For example, on NOAA Cloud platforms (AWS, Azure) the
Slurm partition directive is not used and the corresponding line must be commented out
in the Slurm templates:

.. code-block:: text

   ##SBATCH --partition=@[PARTITION]

Other common adjustments include wall-clock limits, node counts, and any
platform-specific environment variables required before launching the container.

Running with a Job Scheduler (Slurm or PBS)
--------------------------------------------

When ``SCHEDULER`` is set to ``slurm`` or ``pbs`` in ``rt_container.conf``, set ``ACCNR``, ``PARTITION``, and ``QUEUE`` appropriately and run the driver from a login node:

.. code-block:: console

   ./rt_container.sh

The driver submits each compile and test job to the scheduler and blocks until the job finishes before submitting the next one. Progress is reported on the terminal; full output is captured in ``${RUNDIR_ROOT}/logs/``.

Running Interactively (No Scheduler)
--------------------------------------

When ``SCHEDULER`` is set to ``none``, jobs run directly on the current host — suitable for an allocated compute node or single-workstation development. Request an interactive compute node allocation before running the driver.

On **Slurm** systems:

.. code-block:: console

   salloc -N 1 -n <cores> -A <account> -t <time> -q <qos> --partition=<partition>

On **PBS** systems:

.. code-block:: console

   qsub -I -l walltime=<time> -A <account> -q <queue> -l select=1:ncpus=<cores>:mpiprocs=<cores>

After the allocation is granted (and connecting via ``ssh`` to the compute node if required), run the driver:

.. code-block:: console

   cd tests
   ./rt_container.sh

Set ``MPI_LAUNCH`` in header line 2 to ``mpirun`` or ``mpiexec`` (default: ``mpirun``). The driver starts the container once and then runs MPI tasks entirely inside the container, which is the correct approach for single-node interactive runs.

.. note::

   The ``--mpi=pmi2`` flag is a Slurm ``srun``-specific option and should **not** be used
   with ``mpirun`` or ``mpiexec``. The ``none``-scheduler path omits it automatically.

.. _container-rt-output:

===================
Run Directory
===================

After the driver starts, it creates the following structure under ``RUNDIR_ROOT``:

.. code-block:: text

   ${RUNDIR_ROOT}/
   ├── logs/                         # per-job log files and timestamps
   ├── compile_<compile_id>/         # compile working directory
   │   ├── job_card                  # generated compile job script
   │   ├── container_compile.sh      # script executed inside the container
   │   ├── modulefiles/              # modulefile staged for the build
   │   └── out / err                 # job stdout and stderr
   └── <test_id>_<compiler>/         # test working directory
       ├── job_card                  # generated test job script
       ├── fv3_container_run.sh      # wrapper executed inside the container
       ├── modulefiles/              # modulefile staged for the run
       └── out / err                 # job stdout and stderr

A convenience symlink ``tests/run_dir`` is created pointing to ``RUNDIR_ROOT``, making it easy to navigate to the run directory without knowing the full path. This symlink is not created if the user has already set ``RUNDIR_ROOT`` to ``${PATHRT}/run_dir``.

A PASS/FAIL summary is printed to the terminal when all tests have finished. The driver exits with status 1 if any compile or test failed, and 0 if all succeeded.
