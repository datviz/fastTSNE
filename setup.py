import os
import tempfile
import warnings
from distutils import ccompiler
from distutils.command.build_ext import build_ext
from distutils.errors import CompileError, LinkError
from os.path import join

import setuptools
from setuptools import setup, Extension

try:
    import numpy
except ImportError:
    from subprocess import call
    call(["pip", "install", "numpy"])

import numpy as np


def has_c_library(library, extension=".c"):
    """Check whether a C/C++ library is available on the system to the compiler.

    Parameters
    ----------
    library: str
        The library we want to check for e.g. if we are interested in FFTW3, we
        want to check for `fftw3.h`, so this parameter will be `fftw3`.
    extension: str
        If we want to check for a C library, the extension is `.c`, for C++
        `.cc`, `.cpp` or `.cxx` are accepted.

    Returns
    -------
    bool
        Whether or not the library is available.

    """
    with tempfile.TemporaryDirectory(dir=".") as directory:
        name = join(directory, "%s%s" % (library, extension))
        with open(name, "w") as f:
            f.write("#include <%s.h>\n" % library)
            f.write("int main() {}\n")

        # Get a compiler instance
        compiler = ccompiler.new_compiler()
        assert isinstance(compiler, ccompiler.CCompiler)

        try:
            # Try to compile the file using the C compiler
            compiler.link_executable(compiler.compile([name]), name)
            return True
        except (CompileError, LinkError):
            return False


class CythonBuildExt(build_ext):

    COMPILER_FLAGS = {
        "unix": {"openmp": "-fopenmp",
                 "optimize": "-O3",
                 "fftw": "-lfftw3",
                 "math": "-lm",
                 },
        "msvc": {"openmp": "/openmp",
                 "optimize": "/Ox",
                 "fftw": "/lfftw3",
                 "math": "/lm"
                 },
    }

    def build_extensions(self):
        # Automatically append the file extension based on language.
        # ``cythonize`` does this for us automatically, so it's not necessary if
        # that was run
        if not HAS_CYTHON:
            for extension in self.extensions:
                for idx, source in enumerate(extension.sources):
                    base, ext = os.path.splitext(source)
                    base += ".cpp" if extension.language == "c++" else ".c"
                    extension.sources[idx] = base

        # Optimization compiler/linker flags are added appropriately
        flags = self.COMPILER_FLAGS[self.compiler.compiler_type]
        compile_flags = [flags["optimize"]]
        link_flags = [flags["optimize"]]

        # Map any existing compile/link flags into compiler specific ones
        def map_flags(ls):
            return list(map(lambda flag: flags.get(flag, flag), ls))

        for extension in self.extensions:
            extension.extra_compile_args = map_flags(extension.extra_compile_args)
            extension.extra_link_args = map_flags(extension.extra_link_args)

        # We will disable openmp flags if the compiler doesn"t support it. This
        # is only really an issue with OSX clang
        if has_c_library("omp"):
            print("Found openmp. Compiling with openmp flags...")
            compile_flags.append(flags["openmp"]), link_flags.append(flags["openmp"])
        else:
            warnings.warn(
                "You appear to be using a compiler which does not support "
                "openMP, meaning that the library will not be able to run on "
                "multiple cores. Please install/enable openMP to use multiple "
                "cores."
            )

        for extension in self.extensions:
            extension.extra_compile_args.extend(compile_flags)
            extension.extra_link_args.extend(link_flags)

        # We typically use numpy includes in our Cython files, so we"ll add the
        # appropriate headers here
        for extension in self.extensions:
            extension.include_dirs.append(np.get_include())

        super().build_extensions()


extensions = [
    Extension("fastTSNE.vptree", ["fastTSNE/vptree.pyx"], language="c++"),
    Extension("fastTSNE.quad_tree", ["fastTSNE/quad_tree.pyx"]),
    Extension("fastTSNE._tsne", ["fastTSNE/_tsne.pyx"]),
    Extension("fastTSNE.kl_divergence", ["fastTSNE/kl_divergence.pyx"]),
]

# Check if we have access to FFTW3 and if so, use that implementation
if has_c_library("fftw3"):
    print("FFTW3 header files found. Using FFTW implementation of FFT.")
    extensions.append(
        Extension("fastTSNE._matrix_mul.matrix_mul",
                  ["fastTSNE/_matrix_mul/matrix_mul_fftw3.pyx"],
                  extra_compile_args=["fftw", "math"],
                  extra_link_args=["fftw", "math"],
                  )
        )
else:
    print("FFTW3 header files not found. Using numpy implementation of FFT.")
    extensions.append(
        Extension("fastTSNE._matrix_mul.matrix_mul",
                  ["fastTSNE/_matrix_mul/matrix_mul_numpy.pyx"])
    )

try:
    from Cython.Build import cythonize
    extensions = cythonize(extensions)
    HAS_CYTHON = True
except ImportError:
    HAS_CYTHON = False

setup(
    name="fastTSNE",
    description="",
    version="0.2.16",
    license="BSD-3-Clause",

    author="Pavlin Poličar",
    author_email="pavlin.g.p@gmail.com",
    url="https://github.com/pavlin-policar/fastTSNE",
    project_urls={
        "Documentation": "https://fasttsne.readthedocs.io/",
        "Source": "https://github.com/pavlin-policar/fastTSNE",
        "Issue Tracker": "https://github.com/pavlin-policar/fastTSNE/issues",
    },
    classifiers=[
        "Development Status :: 4 - Beta",
        "Intended Audience :: Science/Research",
        "Intended Audience :: Developers",
        "Topic :: Software Development",
        "Topic :: Scientific/Engineering",
        "Operating System :: Microsoft :: Windows",
        "Operating System :: POSIX",
        "Operating System :: Unix",
        "Operating System :: MacOS",
        "License :: OSI Approved",
        "Programming Language :: Python :: 3",
        "Topic :: Scientific/Engineering :: Artificial Intelligence",
        "Topic :: Scientific/Engineering :: Visualization",
        "Topic :: Software Development :: Libraries :: Python Modules",
    ],

    packages=setuptools.find_packages(include=["fastTSNE", "fastTSNE.*"]),
    install_requires=[
        "numpy>1.14",
        "numba>=0.38.1",
        "scikit-learn>=0.20",
        "scipy",
    ],

    ext_modules=extensions,
    cmdclass={"build_ext": CythonBuildExt},
)
