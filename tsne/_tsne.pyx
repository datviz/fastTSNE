# cython: profile=True
# cython: boundscheck=False
# cython: wraparound=False
# cython: cdivision=True
cimport numpy as np
import numpy as np
from .quad_tree cimport QuadTree, Node, is_duplicate
from cython.parallel import prange, parallel
from cpython.mem cimport PyMem_Malloc, PyMem_Free
from libc.stdlib cimport malloc, free


cdef extern from 'fftw3.h':
    int fftw_init_threads()
    void fftw_plan_with_nthreads(int)

    cdef int FFTW_FORWARD
    cdef int FFTW_BACKWARD
    cdef unsigned FFTW_ESTIMATE

    ctypedef double fftw_complex[2]

    void *fftw_malloc(size_t)
    void fftw_free(void *)

    ctypedef struct _fftw_plan:
       pass

    ctypedef _fftw_plan *fftw_plan

    void fftw_execute(fftw_plan)
    void fftw_destroy_plan(fftw_plan)
    void fftw_print_plan(fftw_plan)
    fftw_plan fftw_plan_dft_1d(int, fftw_complex*, fftw_complex*, int, unsigned)
    fftw_plan fftw_plan_dft_r2c_2d(int, int, double*, fftw_complex*, unsigned)
    fftw_plan fftw_plan_dft_c2r_2d(int, int, fftw_complex*, double*, unsigned)


cdef double EPSILON = np.finfo(np.float64).eps


cdef extern from 'math.h':
    double sqrt(double x) nogil
    double log(double x) nogil
    double exp(double x) nogil
    double fabs(double x) nogil
    double isinf(long double) nogil
    double INFINITY


cpdef np.ndarray[np.float64_t, ndim=2] compute_gaussian_perplexity(
    double[:, :] distances,
    double desired_perplexity,
    double perplexity_tol=1e-8,
    Py_ssize_t max_iter=200,
    Py_ssize_t num_threads=1,
):
    cdef:
        Py_ssize_t n_new_points = distances.shape[0]
        Py_ssize_t n_existing_points = distances.shape[1]
        double[:, :] P = np.zeros_like(distances)
        double[:] beta = np.ones(n_new_points)

        Py_ssize_t i, j, iteration
        double desired_entropy = log(desired_perplexity)

        double min_beta, max_beta, sum_Pi, entropy, entropy_diff

    if num_threads < 1:
        num_threads = 1

    for i in prange(n_new_points, nogil=True, schedule='guided', num_threads=num_threads):
        min_beta, max_beta = -INFINITY, INFINITY

        for iteration in range(max_iter):
            sum_Pi, entropy = 0, 0
            for j in range(n_existing_points):
                P[i, j] = exp(-distances[i, j] * beta[i])
                entropy = entropy + distances[i, j] * P[i, j]
                sum_Pi = sum_Pi + P[i, j]

            sum_Pi = sum_Pi + EPSILON

            entropy = log(sum_Pi) + beta[i] * entropy / sum_Pi
            entropy_diff = entropy - desired_entropy

            if fabs(entropy_diff) <= perplexity_tol:
                break

            if entropy_diff > 0:
                min_beta = beta[i]
                if isinf(max_beta):
                    beta[i] *= 2
                else:
                    beta[i] = (beta[i] + max_beta) / 2
            else:
                max_beta = beta[i]
                if isinf(min_beta):
                    beta[i] /= 2
                else:
                    beta[i] = (beta[i] + min_beta) / 2

        for j in range(n_existing_points):
            P[i, j] /= sum_Pi

    return np.asarray(P, dtype=np.float64)


cpdef tuple compute_positive_gradients(
    int[:] indices,
    int[:] indptr,
    double[:] P_data,
    double[:, ::1] embedding,
    double[:, ::1] reference_embedding,
    double[:, ::1] gradient,
    double dof,
    Py_ssize_t num_threads=1,
    bint should_eval_error=False,
):
    cdef:
        Py_ssize_t n_samples = gradient.shape[0]
        Py_ssize_t n_dims = gradient.shape[1]
        double * diff
        double d_ij, p_ij, q_ij, kl_divergence = 0, sum_P = 0

        Py_ssize_t i, j, k, d

    if num_threads < 1:
        num_threads = 1

    with nogil, parallel(num_threads=num_threads):
        # Use `malloc` here instead of `PyMem_Malloc` because we're in a
        # `nogil` clause and we won't be allocating much memory
        diff = <double *>malloc(n_dims * sizeof(double))
        if not diff:
            with gil:
                raise MemoryError()

        for i in prange(n_samples, schedule='guided'):
            # Iterate over all the neighbors `j` and sum up their contribution
            for k in range(indptr[i], indptr[i + 1]):
                j = indices[k]
                p_ij = P_data[k]
                # Compute the direction of the points attraction and the
                # squared euclidean distance between the points
                d_ij = 0
                for d in range(n_dims):
                    diff[d] = embedding[i, d] - reference_embedding[j, d]
                    d_ij = d_ij + diff[d] ** 2

                q_ij = dof / (dof + d_ij)
                if dof != 1:
                    q_ij = q_ij ** (dof + 1) / 2

                # Compute F_{attr} of point `j` on point `i`
                for d in range(n_dims):
                    gradient[i, d] = gradient[i, d] + q_ij * p_ij * diff[d]

                # Evaluating the following expressions can slow things down
                # considerably if evaluated every iteration. Note that the q_ij
                # is unnormalized, so we need to normalize once the sum of q_ij
                # is known
                if should_eval_error:
                    sum_P += p_ij
                    kl_divergence += p_ij * log(p_ij / (q_ij + EPSILON))

        free(diff)

    return sum_P, kl_divergence


cpdef double compute_negative_gradients_bh(
    QuadTree tree,
    double[:, ::1] embedding,
    double[:, ::1] gradient,
    double theta=0.5,
    double dof=1,
    Py_ssize_t num_threads=1,
):
    """Estimate the negative tSNE gradient using the Barnes Hut approximation.
    
    Notes
    -----
    Changes the gradient inplace to avoid needless memory allocation. As
    such, this must be run before estimating the positive gradients, since
    the negative gradient must be normalized at the end with the sum of
    q_{ij}s.
    
    """
    cdef:
        Py_ssize_t i, j, num_points = embedding.shape[0]
        double sum_Q = 0
        double * sum_Qi = <double *>PyMem_Malloc(num_points * sizeof(double))

    if num_threads < 1:
        num_threads = 1

    # In order to run gradient estimation in parallel, we need to pass each
    # worker it's own memory slot to write sum_Qs
    for i in range(num_points):
        sum_Qi[i] = 0

    for i in prange(num_points, nogil=True, num_threads=num_threads, schedule='guided'):
        estimate_negative_gradient(
            &tree.root, &embedding[i, 0], &gradient[i, 0], &sum_Qi[i], theta, dof)

    for i in range(num_points):
        sum_Q += sum_Qi[i]

    PyMem_Free(sum_Qi)

    # Normalize q_{ij}s
    for i in range(gradient.shape[0]):
        for j in range(gradient.shape[1]):
            gradient[i, j] /= sum_Q + EPSILON

    return sum_Q


cdef void estimate_negative_gradient(
    Node * node,
    double * point,
    double * gradient,
    double * sum_Q,
    double theta,
    double dof,
) nogil:
    # Make sure that we spend no time on empty nodes or self-interactions
    if node.num_points == 0 or node.is_leaf and is_duplicate(node, point):
        return

    cdef:
        double distance = EPSILON
        double q_ij
        Py_ssize_t d

    # Compute the squared euclidean disstance in the embedding space from the
    # new point to the center of mass
    for d in range(node.n_dims):
        distance += (node.center_of_mass[d] - point[d]) ** 2

    # Check whether we can use this node as a summary
    if node.is_leaf or node.length / sqrt(distance) < theta:
        q_ij = dof / (dof + distance)
        if dof != 1:
            q_ij = q_ij ** (dof + 1) / 2
        sum_Q[0] += node.num_points * q_ij

        for d in range(node.n_dims):
            gradient[d] -= node.num_points * q_ij ** 2 * (point[d] - node.center_of_mass[d])

        return

    # Otherwise we have to look for summaries in the children
    for d in range(1 << node.n_dims):
        estimate_negative_gradient(&node.children[d], point, gradient, sum_Q, theta, dof)


cdef double cauchy_1d(double x, double y):
    return (1 + (x - y) ** 2) ** -2


cdef double cauchy_2d(double x1, double x2, double y1, double y2):
    return (1 + (x1 - y1) ** 2 + (x2 - y2) ** 2) ** -2


cdef void interpolate(
    Py_ssize_t n_interpolation_points,
    Py_ssize_t N,
    double[::1] y_in_box,
    double[::1] y_tilde_spacings,
    double[:, ::1] interpolated_values,
):
    cdef double[::1] denominator = np.empty(n_interpolation_points, dtype=float)
    cdef Py_ssize_t i, j, k

    for i in range(n_interpolation_points):
        denominator[i] = 1
        for j in range(n_interpolation_points):
            if i != j:
                denominator[i] *= y_tilde_spacings[i] - y_tilde_spacings[j]

    for i in range(N):
        for j in range(n_interpolation_points):
            interpolated_values[i, j] = 1
            for k in range(n_interpolation_points):
                if j != k:
                    interpolated_values[i, j] *= y_in_box[i] - y_tilde_spacings[k]
            interpolated_values[i, j] /= denominator[j]


cpdef double compute_negative_gradients_fft_1d(
    double[::1] embedding,
    double[::1] gradient,
    Py_ssize_t n_interpolation_points=3,
    Py_ssize_t min_num_intervals=10,
    double intervals_per_int=1,
):
    cdef Py_ssize_t i, j, d, box_idx, N = embedding.shape[0]
    cdef double y_max = -INFINITY, y_min = INFINITY
    # Determine the min/max values of the embedding
    for i in range(N):
        if embedding[i] < y_min:
            y_min = embedding[i]
        elif embedding[i] > y_max:
            y_max = embedding[i]

    cdef int n_boxes = <int>max(min_num_intervals, (y_max - y_min) / intervals_per_int)
    cdef double box_width = (y_max - y_min) / n_boxes

    cdef int n_terms = 3
    cdef double[:, ::1] charges_Qij = np.empty((N, n_terms), dtype=float)
    for i in range(N):
        charges_Qij[i, 0] = 1
        charges_Qij[i, 1] = embedding[i]
        charges_Qij[i, 2] = embedding[i] ** 2

    # Compute the box bounds
    cdef double[::1] box_lower_bounds = np.empty(n_boxes, dtype=float)
    cdef double[::1] box_upper_bounds = np.empty(n_boxes, dtype=float)
    for box_idx in range(n_boxes):
        box_lower_bounds[box_idx] = box_idx * box_width + y_min
        box_upper_bounds[box_idx] = (box_idx + 1) * box_width + y_min

    cdef int total_interpolation_points = n_interpolation_points * n_boxes
    # Prepare the interpolants
    cdef double[::1] y_tilde_spacing = np.empty(n_interpolation_points, dtype=float)
    cdef double h = 1. / n_interpolation_points
    y_tilde_spacing[0] = h / 2
    for i in range(1, n_interpolation_points):
        y_tilde_spacing[i] = y_tilde_spacing[i - 1] + h

    cdef double[::1] y_tilde = np.empty(total_interpolation_points, dtype=float)
    h = h * box_width
    y_tilde[0] = h / 2 + y_min
    for i in range(1, total_interpolation_points):
        y_tilde[i] = y_tilde[i - 1] + h

    # Evaluate the kernel at the interpolation nodes and form the embedded
    # generating kernel vector for a circulant matrix
    cdef:
        complex[::1] kernel_tilde = np.zeros(2 * total_interpolation_points, dtype=complex)
        complex[::1] fft_kernel_tilde = np.empty(2 * total_interpolation_points, dtype=complex)

    for i in range(total_interpolation_points):
        kernel_tilde[total_interpolation_points + i] = cauchy_1d(y_tilde[0], y_tilde[i])
    for i in range(1, total_interpolation_points):
        kernel_tilde[i] = kernel_tilde[2 * total_interpolation_points - i]

    # Compute the FFT of the kernel vector
    cdef fftw_plan plan_dft, plan_idft
    plan_dft = fftw_plan_dft_1d(
        2 * total_interpolation_points,
        <fftw_complex *>(&kernel_tilde[0]),
        <fftw_complex *>(&fft_kernel_tilde[0]),
        FFTW_FORWARD, FFTW_ESTIMATE,
    )
    fftw_execute(plan_dft)
    fftw_destroy_plan(plan_dft)

    # Determine which box each point belongs to
    cdef int *point_box_idx = <int *>PyMem_Malloc(N * sizeof(int))
    for i in range(N):
        box_idx = <int>((embedding[i] - y_min) / box_width)
        # The right most point maps directly into `n_boxes`, while it should
        # belong to the last box
        if box_idx >= n_boxes:
            box_idx = n_boxes - 1

        point_box_idx[i] = box_idx

    # Compute the relative position of each point in its box
    cdef double[::1] y_in_box = np.empty(N, dtype=float)
    for i in range(N):
        box_idx = point_box_idx[i]
        y_in_box[i] = (embedding[i] - box_lower_bounds[box_idx]) / box_width;

    # Step 1: Interpolate kernel using Lagrange polynomials and compute the w
    # coefficients
    cdef double[:, ::1] interpolated_values = np.empty((N, n_interpolation_points), dtype=float)
    interpolate(n_interpolation_points, N, y_in_box, y_tilde_spacing, interpolated_values)

    cdef double[:, ::1] w_coeffs = np.zeros((total_interpolation_points, n_terms), dtype=float)
    for i in range(N):
        box_idx = point_box_idx[i] * n_interpolation_points
        for j in range(n_interpolation_points):
            for d in range(n_terms):
                w_coeffs[box_idx + j, d] += interpolated_values[i, j] * charges_Qij[i, d]

    cdef double[:, ::1] embedded_w_coeffs = np.zeros((2 * total_interpolation_points, n_terms), dtype=float)
    for i in range(total_interpolation_points):
        for d in range(n_terms):
            embedded_w_coeffs[total_interpolation_points + i, d] = w_coeffs[i, d]

    # Step 2: Compute the values v_{m, n} at the equispaced nodes, multiply the
    # kernel matrix with the coefficients w
    cdef complex[::1] fft_w_coeffs = np.empty(2 * total_interpolation_points, dtype=complex)
    cdef double[:, ::1] y_tilde_values = np.empty((total_interpolation_points, n_terms), dtype=float)

    plan_dft = fftw_plan_dft_1d(
        2 * total_interpolation_points,
        <fftw_complex *>(&fft_w_coeffs[0]),
        <fftw_complex *>(&fft_w_coeffs[0]),
        FFTW_FORWARD, FFTW_ESTIMATE,
    )
    plan_idft = fftw_plan_dft_1d(
        2 * total_interpolation_points,
        <fftw_complex *>(&fft_w_coeffs[0]),
        <fftw_complex *>(&fft_w_coeffs[0]),
        FFTW_BACKWARD, FFTW_ESTIMATE,
    )

    for d in range(n_terms):
        for i in range(2 * total_interpolation_points):
            fft_w_coeffs[i] = embedded_w_coeffs[i, d]

        fftw_execute(plan_dft)

        # Take the Hadamard product of two complex vectors
        for i in range(2 * total_interpolation_points):
            fft_w_coeffs[i] = fft_w_coeffs[i] * fft_kernel_tilde[i]

        fftw_execute(plan_idft)

        for i in range(total_interpolation_points):
            # FFTW doesn't perform IDFT normalization, so we have to do it
            # ourselves. This is done by multiplying the result with the number
            #  of points in the input
            y_tilde_values[i, d] = fft_w_coeffs[i].real / (total_interpolation_points * 2)

    fftw_destroy_plan(plan_dft)
    fftw_destroy_plan(plan_idft)

    # Step 3: Compute the potentials \tilde{\phi}
    cdef double[:, ::1] potentials = np.zeros((N, n_terms), dtype=float)
    for i in range(N):
        box_idx = point_box_idx[i] * n_interpolation_points
        for j in range(n_interpolation_points):
            for d in range(n_terms):
                potentials[i, d] += interpolated_values[i, j] * y_tilde_values[box_idx + j, d]

    cdef double z_sum = 0
    for i in range(N):
        phi1 = potentials[i, 0]
        phi2 = potentials[i, 1]
        phi3 = potentials[i, 2]

        z_sum += (1 + embedding[i] ** 2) * phi1 - 2 * embedding[i] * phi2 + phi3
    z_sum -= N

    for i in range(N):
        gradient[i] -= (embedding[i] * potentials[i, 0] - potentials[i, 1]) / z_sum

    return z_sum


cpdef double compute_negative_gradients_fft_2d(
    double[:, ::1] embedding,
    double[:, ::1] gradient,
    Py_ssize_t n_interpolation_points=3,
    Py_ssize_t min_num_intervals=10,
    double intervals_per_int=1,
):
    cdef Py_ssize_t i, j, d, box_idx, N = embedding.shape[0], n_dims = embedding.shape[1]
    cdef double coord_max = -INFINITY, coord_min = INFINITY
    # Determine the min/max values of the embedding
    for i in range(N):
        if embedding[i, 0] < coord_min:
            coord_min = embedding[i, 0]
        elif embedding[i, 0] > coord_max:
            coord_max = embedding[i, 0]
        if embedding[i, 1] < coord_min:
            coord_min = embedding[i, 1]
        elif embedding[i, 1] > coord_max:
            coord_max = embedding[i, 1]

    cdef int n_boxes_1d = <int>max(min_num_intervals, (coord_max - coord_min) / intervals_per_int)
    cdef int n_total_boxes = n_boxes_1d ** 2
    cdef double box_width = (coord_max - coord_min) / n_boxes_1d

    cdef int n_terms = 4
    cdef double[:, ::1] charges_Qij = np.empty((N, n_terms), dtype=float)
    for i in range(N):
        charges_Qij[i, 0] = 1
        charges_Qij[i, 1] = embedding[i, 0]
        charges_Qij[i, 2] = embedding[i, 1]
        charges_Qij[i, 3] = embedding[i, 0] ** 2 + embedding[i, 1] ** 2

    # Compute the box bounds
    cdef:
        double[::1] box_x_lower_bounds = np.empty(n_total_boxes, dtype=float)
        double[::1] box_x_upper_bounds = np.empty(n_total_boxes, dtype=float)
        double[::1] box_y_lower_bounds = np.empty(n_total_boxes, dtype=float)
        double[::1] box_y_upper_bounds = np.empty(n_total_boxes, dtype=float)

    for i in range(n_boxes_1d):
        for j in range(n_boxes_1d):
            box_x_lower_bounds[i * n_boxes_1d + j] = j * box_width + coord_min
            box_x_upper_bounds[i * n_boxes_1d + j] = (j + 1) * box_width + coord_min

            box_y_lower_bounds[i * n_boxes_1d + j] = i * box_width + coord_min
            box_y_upper_bounds[i * n_boxes_1d + j] = (i + 1) * box_width + coord_min

    # Prepare the interpolants
    cdef double[::1] y_tilde_spacing = np.empty(n_interpolation_points, dtype=float)
    cdef double h = 1. / n_interpolation_points
    y_tilde_spacing[0] = h / 2
    for i in range(1, n_interpolation_points):
        y_tilde_spacing[i] = y_tilde_spacing[i - 1] + h

    cdef:
        int n_interpolation_points_1d = n_interpolation_points * n_boxes_1d
        double[::1] y_tilde = np.empty(n_interpolation_points_1d, dtype=float)
        double[::1] x_tilde = np.empty(n_interpolation_points_1d, dtype=float)

    h = h * box_width
    x_tilde = np.empty(n_interpolation_points_1d)
    y_tilde = np.empty(n_interpolation_points_1d)
    x_tilde[0] = coord_min + h / 2
    y_tilde[0] = coord_min + h / 2
    for i in range(1, n_interpolation_points_1d):
        x_tilde[i] = x_tilde[i - 1] + h
        y_tilde[i] = y_tilde[i - 1] + h

    # Evaluate the kernel at the interpolation nodes and form the embedded
    # generating kernel vector for a circulant matrix
    cdef:
        int n_fft_coeffs = 2 * n_interpolation_points_1d
        double[:, ::1] kernel_tilde = np.zeros((n_fft_coeffs, n_fft_coeffs), dtype=float)
        complex[::1] fft_kernel_tilde = np.empty(n_fft_coeffs * (n_fft_coeffs / 2 + 1), dtype=complex)

    for i in range(n_interpolation_points_1d):
        for j in range(n_interpolation_points_1d):
            tmp = cauchy_2d(y_tilde[0], x_tilde[0], y_tilde[i], x_tilde[j])

            kernel_tilde[n_interpolation_points_1d + i, n_interpolation_points_1d + j] = tmp
            kernel_tilde[n_interpolation_points_1d - i, n_interpolation_points_1d + j] = tmp
            kernel_tilde[n_interpolation_points_1d + i, n_interpolation_points_1d - j] = tmp
            kernel_tilde[n_interpolation_points_1d - i, n_interpolation_points_1d - j] = tmp

    # Compute the FFT of the kernel vector
    cdef fftw_plan plan_dft, plan_idft
    plan_dft = fftw_plan_dft_r2c_2d(
        n_fft_coeffs, n_fft_coeffs,
        &kernel_tilde[0, 0], <fftw_complex *>(&fft_kernel_tilde[0]),
        FFTW_ESTIMATE,
    )
    fftw_execute(plan_dft)
    fftw_destroy_plan(plan_dft)

    # Determine which box each point belongs to
    cdef int *point_box_idx = <int *>PyMem_Malloc(N * sizeof(int))
    cdef int box_x_idx, box_y_idx
    for i in range(N):
        box_x_idx = <int>((embedding[i, 0] - coord_min) / box_width)
        box_y_idx = <int>((embedding[i, 1] - coord_min) / box_width)
        # The right most point maps directly into `n_boxes`, while it should
        # belong to the last box
        if box_x_idx >= n_boxes_1d:
            box_x_idx = n_boxes_1d - 1
        if box_y_idx >= n_boxes_1d:
            box_y_idx = n_boxes_1d - 1

        point_box_idx[i] = box_y_idx * n_boxes_1d + box_x_idx

    # Compute the relative position of each point in its box
    cdef:
        double[::1] x_in_box = np.empty(N, dtype=float)
        double[::1] y_in_box = np.empty(N, dtype=float)

    for i in range(N):
        box_idx = point_box_idx[i]
        x_min = box_x_lower_bounds[box_idx]
        y_min = box_y_lower_bounds[box_idx]
        x_in_box[i] = (embedding[i, 0] - x_min) / box_width
        y_in_box[i] = (embedding[i, 1] - y_min) / box_width

    # Step 1: Interpolate kernel using Lagrange polynomials and compute the w
    # coefficients
    cdef double[:, ::1] x_interpolated_values = np.empty((N, n_interpolation_points), dtype=float)
    interpolate(n_interpolation_points, N, x_in_box, y_tilde_spacing, x_interpolated_values)
    cdef double[:, ::1] y_interpolated_values = np.empty((N, n_interpolation_points), dtype=float)
    interpolate(n_interpolation_points, N, y_in_box, y_tilde_spacing, y_interpolated_values)

    # Compute the w coefficients
    cdef int total_interpolation_points = n_total_boxes * n_interpolation_points ** 2
    cdef double[:, ::1] w_coefficients = np.zeros((total_interpolation_points, n_terms), dtype=float)
    for i in range(N):
        box_idx = point_box_idx[i]
        box_i = box_idx % n_boxes_1d
        box_j = box_idx // n_boxes_1d
        for interp_i in range(n_interpolation_points):
            for interp_j in range(n_interpolation_points):
                idx = (box_i * n_interpolation_points + interp_i) * \
                      (n_boxes_1d * n_interpolation_points) + \
                      (box_j * n_interpolation_points) + \
                      interp_j
                for d in range(n_terms):
                    w_coefficients[idx, d] += \
                        x_interpolated_values[i, interp_i] * \
                        y_interpolated_values[i, interp_j] * \
                        charges_Qij[i, d]

    cdef:
        double[::1] mpol_sort = np.zeros(total_interpolation_points)
        double[:, ::1] y_tilde_values = np.zeros((total_interpolation_points, n_terms))
        double[:, ::1] zmpol = np.zeros((n_fft_coeffs, n_fft_coeffs))
        complex[::1] fft_w_coeffs = np.zeros(n_fft_coeffs * (n_fft_coeffs / 2 + 1), dtype=complex)
        double[:, ::1] zmpolfo = np.zeros((n_fft_coeffs, n_fft_coeffs))

    plan_dft = fftw_plan_dft_r2c_2d(
        n_fft_coeffs, n_fft_coeffs,
        &zmpol[0, 0], <fftw_complex *>(&fft_w_coeffs[0]),
        FFTW_ESTIMATE
    )
    plan_idft = fftw_plan_dft_c2r_2d(
        n_fft_coeffs, n_fft_coeffs,
        <fftw_complex *>(&fft_w_coeffs[0]), &zmpolfo[0, 0],
        FFTW_ESTIMATE
    )

    for d in range(n_terms):
        for i in range(total_interpolation_points):
            mpol_sort[i] = w_coefficients[i, d]

        for i in range(n_interpolation_points_1d):
            for j in range(n_interpolation_points_1d):
                zmpol[i, j] = mpol_sort[i * n_interpolation_points_1d + j]

        fftw_execute(plan_dft)

        # Take the Hadamard product of two complex vectors
        for i in range(n_fft_coeffs * (n_fft_coeffs / 2 + 1)):
            fft_w_coeffs[i].real = fft_w_coeffs[i].real * fft_kernel_tilde[i].real - \
                fft_w_coeffs[i].imag * fft_kernel_tilde[i].imag
            fft_w_coeffs[i].imag = fft_w_coeffs[i].real * fft_kernel_tilde[i].imag + \
                fft_kernel_tilde[i].real * fft_w_coeffs[i].imag

        # Invert the computed values at the interpolated nodes
        fftw_execute(plan_idft)
        # FFTW doesn't perform IDFT normalization, so we have to do it
        # ourselves. This is done by multiplying the result with the number of
        # points in the input
        for i in range(n_interpolation_points_1d):
            for j in range(n_interpolation_points_1d):
                idx = i * n_interpolation_points_1d + j
                mpol_sort[idx] = zmpolfo[n_interpolation_points_1d + i,
                                         n_interpolation_points_1d + j] / n_fft_coeffs ** 2

        for i in range(n_interpolation_points_1d ** 2):
            y_tilde_values[i, d] = mpol_sort[i]

    fftw_destroy_plan(plan_dft)
    fftw_destroy_plan(plan_idft)

    # Step 3: Compute the potentials \tilde{\phi}
    cdef double[:, ::1] potentials = np.zeros((N, n_terms), dtype=float)
    for i in range(N):
        box_idx = point_box_idx[i]
        box_i = box_idx % n_boxes_1d
        box_j = box_idx // n_boxes_1d
        for interp_i in range(n_interpolation_points):
            for interp_j in range(n_interpolation_points):
                idx = (box_i * n_interpolation_points + interp_i) * \
                      (n_boxes_1d * n_interpolation_points) + \
                      (box_j * n_interpolation_points) + \
                      interp_j
                for d in range(n_terms):
                    potentials[i, d] += \
                        x_interpolated_values[i, interp_i] * \
                        y_interpolated_values[i, interp_j] * \
                        y_tilde_values[idx, d]

    cdef double z_sum = 0
    for i in range(N):
        phi1 = potentials[i, 0]
        phi2 = potentials[i, 1]
        phi3 = potentials[i, 2]
        phi4 = potentials[i, 3]
        y1 = embedding[i, 0]
        y2 = embedding[i, 1]

        z_sum += (1 + y1 ** 2 + y2 ** 2) * phi1 - 2 * (y1 * phi2 + y2 * phi3) + phi4
    z_sum -= N

    for i in range(N):
        gradient[i, 0] -= (embedding[i, 0] * potentials[i, 0] - potentials[i, 1]) / z_sum
        gradient[i, 1] -= (embedding[i, 1] * potentials[i, 0] - potentials[i, 2]) / z_sum

    return z_sum