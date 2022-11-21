#include <cstdlib>
#include <cuda_runtime.h>
#include <algorithm>
#include <vector>
#include <mma.h>
using namespace nvcuda;
constexpr int WMMA_M = 16;
constexpr int WMMA_N = 16;
constexpr int WMMA_K = 16;
constexpr int BLOCK_M = 256;
constexpr int BLOCK_N = 128;
constexpr int BLOCK_K = 64;
#include <iostream>

__global__ void i8gemm256x128x64(const int8_t *A, const int8_t *B, int32_t *C,
                                 int M, int N, int K, const int32_t alpha, const int32_t beta)
{
    const int lda = K;
    const int ldb = K;
    const int ldc = N;

    constexpr int sharedLda = 16;
    constexpr int sharedLdb = 16;

    const size_t baseIdx = threadIdx.x;

    const auto warpM = (baseIdx / 32) / 4;
    const auto warpN = (baseIdx / 32) % 4;
    const auto laneId = baseIdx % 32;
    const auto warpId = baseIdx / 32;

    const auto baseA = A + blockIdx.x * BLOCK_M * lda;
    const auto baseB = B + blockIdx.y * BLOCK_N * ldb;
    const auto baseC = C + blockIdx.x * BLOCK_M * ldc + blockIdx.y * BLOCK_N + (warpId / 2) * 64 * ldc + (warpId & 1) * 64;

    constexpr auto sharedASize = BLOCK_M * BLOCK_K;
    constexpr auto sharedBSize = BLOCK_N * BLOCK_K;

    __shared__ int8_t shared_mem[sharedASize + sharedBSize];
    auto sharedA = shared_mem;
    auto sharedB = shared_mem + sharedASize;

    int32_t frag_c[64][2] = {}; // Initialize to 0.
    int32_t frag_a[8][4], frag_b[8][4];

    using copy_t = float4; // I use float to store int, haha.

    copy_t preA[4], preB[2];

#pragma unroll
    for (int k = 0; k < K; k += BLOCK_K)
    {
        // Do 64x64x64 (mnk) mma at a time according to cutlass.
#pragma unroll
        for (int i = 0; i < 4; i++)
        {
            preA[i] = *reinterpret_cast<const copy_t *>(&baseA[(baseIdx % 8 + warpId * 8 + i * 64) * lda + (laneId / 8) * 16 + k]);
        }

#pragma unroll
        for (int i = 0; i < 2; i++)
        {
            preB[i] = *reinterpret_cast<const copy_t *>(&baseB[(baseIdx % 8 + warpId * 8 + i * 64) * ldb + (laneId / 8) * 16 + k]);
        }

#pragma unroll
        for (int i = 0; i < 4; i++)
        {
            *reinterpret_cast<copy_t *>(&sharedA[(baseIdx % 8 + warpId * 8 + i * 64 + (laneId / 8) * BLOCK_M) * sharedLda]) = preA[i];
        }

// Need transpose here, I leave it here for now.
#pragma unroll
        for (int i = 0; i < 2; i++)
        {
            *reinterpret_cast<copy_t *>(&sharedB[(baseIdx % 8 + warpId * 8 + i * 64 + (laneId / 8) * BLOCK_N) * sharedLdb]) = preB[i];
        }

        __syncthreads();
        // Load matrix in 4 stages, could try warp shuff and overlap in the future.
        for (int i = 0; i < 8; i++)
        {
            auto ldA = __cvta_generic_to_shared(&sharedA[((warpId / 2) * 64 + i * 8 + laneId % 8 + (laneId / 8) * BLOCK_M) * sharedLda]);
            auto ldB = __cvta_generic_to_shared(&sharedB[((warpId % 2) * 64 + i * 8 + laneId % 8 + (laneId / 8) * BLOCK_N) * sharedLdb]);
            asm volatile(
                "ldmatrix.sync.aligned.m8n8.x4.shared.b16 {%0, %1, %2, %3}, [%8];"
                "ldmatrix.sync.aligned.m8n8.x4.shared.b16 {%4, %5, %6, %7}, [%9];"
                : "=r"(frag_a[i][0]), "=r"(frag_a[i][1]), "=r"(frag_a[i][2]), "=r"(frag_a[i][3]), "=r"(frag_b[i][0]), "=r"(frag_b[i][1]), "=r"(frag_b[i][2]), "=r"(frag_b[i][3])
                : "l"(ldA), "l"(ldB));
        }

#pragma unroll
        for (int ik = 0; ik < 4; ik++)
        {
#pragma unroll
            for (int im = 0; im < 8; im++)
            {
#pragma unroll
                for (int in = 0; in < 8; in++)
                {
                    asm volatile(
                        "mma.sync.aligned.m8n8k16.row.col.s32.s8.s8.s32 \
                        {%0, %1}, \
                        {%2}, {%3}, \
                        {%0, %1};"
                        : "+r"(frag_c[im * 8 + in][0]), "+r"(frag_c[im * 8 + in][1])
                        : "r"(frag_a[im][ik]), "r"(frag_b[in][ik])); // With an implicit __syncwarp() here.
                }
            }
        }
        __syncthreads();
    }

#pragma unroll
    for (int im = 0; im < 8; im++)
    {
#pragma unroll
        for (int in = 0; in < 8; in++)
        {
            auto idx = im * 8 + in;
            int32_t frag_d[2];
            *reinterpret_cast<int64_t *>(frag_d) = *reinterpret_cast<int64_t *>(&baseC[(im * 8 + laneId / 4) * ldc + in * 8 + (laneId & 3) * 2]); // I'm the reinterpret_cast master!
            frag_d[0] = frag_c[idx][0] * alpha + frag_d[0] * beta;
            frag_d[1] = frag_c[idx][1] * alpha + frag_d[1] * beta;
            *reinterpret_cast<int64_t *>(&baseC[(im * 8 + laneId / 4) * ldc + in * 8 + (laneId & 3) * 2]) = *reinterpret_cast<int64_t *>(frag_d);
        }
    }
}

void i8gemm(int M, int N, int K, int8_t *a, int8_t *b, int32_t *c, int32_t alpha, int32_t beta)
{
    dim3 threadsPerBlock(256);
    dim3 numBlocks((M + BLOCK_M - 1) / BLOCK_M, (N + BLOCK_N - 1) / BLOCK_N);
    i8gemm256x128x64<<<numBlocks, threadsPerBlock>>>(a, b, c, M, N, K, alpha, beta);
}