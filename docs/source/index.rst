fastTSNE: Fast, parallel implementations of t-SNE
=================================================

t-Distributed Stochastic Neighbor Embedding or t-SNE is a popular non-linear dimensionality reduction technique that can be used for visualizing high dimensional data sets.

t-SNE has had several criticisms over the years, which we will address here:

1. t-SNE is *slow*. This criticism likely comes from the fact that some popular packages have slow implementations of t-SNE. Even still, it is true that until very recently, t-SNE did not scale well to larger data sets, however recent theoretical advances by Linderman et. al. [cite] have made t-SNE one of the fastest non-linear dimensionality reduction methods, capable of scaling to millions of samples.

2. t-SNE does not preserve *global structure*. The objective of t-SNE is to preserve local structure i.e. samples close to one another in the ambient space remain close in the embedded space. This can lead to similar clusters of data points drifting to different regions of the embedding space. Recently, Kobak and Berens [cite] introduced a range of tricks that address this problem and better preserve global structure. Often times, these tricks have the nice side effects of drastically decreasing runtime.

3. t-SNE is nonparametric therefore it is impossible to add *new samples* to an existing embedding. This argument is often repeated and likely comes from the fact that most software packages simply did not take the time to implement this. t-SNE is nonparametric meaning that it does not learn a function :math:`f` that projects samples from the ambient space into the embedding space. However, the objective function of t-SNE is well defined and new samples can easily be added into an existing embedding by taking a data point and optimizing its position with respect to the existing embedding.

.. figure:: images/zeisel_2018.png

   A visualization of 160,796 single cell transcriptomes from the mouse nervous system [Zeisel 2018] computed in under 2 minutes using FFT accelerated interpolation and approximate nearest neighbors.


The goal of this project is

1. **Speed**. We provide two fast, parallel implementations of t-SNE, which are comparable to their C++ counterparts in speed.

2. **Interactivity**. This library was built for Orange, an interactive machine learning toolkit. As such, we provide a powerful API which can control all aspects of the t-SNE algorithm and makes it suitable for interactive environments.

3. **Extensibility**. We provide efficient defaults for the typical use case i.e. visualizing high dimensional data. If you aren't happy with the defaults e.g. you would like to use your own nearest neighbor search or would like to embed graph data, this library makes this very easy. This allows for great freedom with experimentation.

4. **Ease of distribution**. FIt-SNE, the reference C++ implementation for the most scalable variant of t-SNE, is not easy to install or distribute. It requires one to preinstall C libraries and requires manual compilation. This package is installable either through :code:`pip` or :code:`conda` with a single command, making it very easy to include in other packages.

.. toctree::
    :maxdepth: 2
    :caption: User Guide

    installation
    getting_started
    tsne_algorithm
    parameters
    benchmarks


.. toctree::
    :maxdepth: 2
    :caption: API Reference

    api/api
