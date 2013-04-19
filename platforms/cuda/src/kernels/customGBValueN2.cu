typedef struct {
    real4 posq;
    real value, temp;
    ATOM_PARAMETER_DATA
#ifdef NEED_PADDING
    float padding;
#endif
} AtomData;

/**
 * Compute a value based on pair interactions.
 */
extern "C" __global__ void computeN2Value(const real4* __restrict__ posq, const unsigned int* __restrict__ exclusions,
        const ushort2* __restrict__ exclusionTiles, unsigned long long* __restrict__ global_value,
#ifdef USE_CUTOFF
        const ushort2* __restrict__ tiles, const unsigned int* __restrict__ interactionCount, real4 periodicBoxSize, real4 invPeriodicBoxSize, 
        unsigned int maxTiles, const real4* __restrict__ blockCenter, const real4* __restrict__ blockSize, const unsigned int* __restrict__ interactingAtoms
#else
        unsigned int numTiles
#endif
        PARAMETER_ARGUMENTS) {
    const unsigned int totalWarps = (blockDim.x*gridDim.x)/TILE_SIZE;
    const unsigned int warp = (blockIdx.x*blockDim.x+threadIdx.x)/TILE_SIZE;
    const unsigned int tgx = threadIdx.x & (TILE_SIZE-1);
    const unsigned int tbx = threadIdx.x - tgx;
    __shared__ AtomData localData[THREAD_BLOCK_SIZE];

    // First loop: process tiles that contain exclusions.
    
    const unsigned int firstExclusionTile = FIRST_EXCLUSION_TILE+warp*(LAST_EXCLUSION_TILE-FIRST_EXCLUSION_TILE)/totalWarps;
    const unsigned int lastExclusionTile = FIRST_EXCLUSION_TILE+(warp+1)*(LAST_EXCLUSION_TILE-FIRST_EXCLUSION_TILE)/totalWarps;
    for (int pos = firstExclusionTile; pos < lastExclusionTile; pos++) {
        const ushort2 tileIndices = exclusionTiles[pos];
        const unsigned int x = tileIndices.x;
        const unsigned int y = tileIndices.y;
        real value = 0;
        unsigned int atom1 = x*TILE_SIZE + tgx;
        real4 posq1 = posq[atom1];
        LOAD_ATOM1_PARAMETERS
#ifdef USE_EXCLUSIONS
        unsigned int excl = exclusions[pos*TILE_SIZE+tgx];
#endif
        if (x == y) {
            // This tile is on the diagonal.

            const unsigned int localAtomIndex = threadIdx.x;
            localData[localAtomIndex].posq = posq1;
            LOAD_LOCAL_PARAMETERS_FROM_1
            for (unsigned int j = 0; j < TILE_SIZE; j++) {
                int atom2 = tbx+j;
                real4 posq2 = localData[atom2].posq;
                real3 delta = make_real3(posq2.x-posq1.x, posq2.y-posq1.y, posq2.z-posq1.z);
#ifdef USE_PERIODIC
                delta.x -= floor(delta.x*invPeriodicBoxSize.x+0.5f)*periodicBoxSize.x;
                delta.y -= floor(delta.y*invPeriodicBoxSize.y+0.5f)*periodicBoxSize.y;
                delta.z -= floor(delta.z*invPeriodicBoxSize.z+0.5f)*periodicBoxSize.z;
#endif
                real r2 = delta.x*delta.x + delta.y*delta.y + delta.z*delta.z;
#ifdef USE_CUTOFF
                if (r2 < CUTOFF_SQUARED) {
#endif
                    real invR = RSQRT(r2);
                    real r = RECIP(invR);
                    LOAD_ATOM2_PARAMETERS
                    atom2 = y*TILE_SIZE+j;
                    real tempValue1 = 0;
                    real tempValue2 = 0;
#ifdef USE_EXCLUSIONS
                    bool isExcluded = (atom1 >= NUM_ATOMS || atom2 >= NUM_ATOMS || !(excl & 0x1));
                    if (!isExcluded && atom1 != atom2) {
#else
                    if (atom1 < NUM_ATOMS && atom2 < NUM_ATOMS && atom1 != atom2) {
#endif
                        COMPUTE_VALUE
                    }
                    value += tempValue1;
#ifdef USE_CUTOFF
                }
#endif
#ifdef USE_EXCLUSIONS
                excl >>= 1;
#endif
            }
        }
        else {
            // This is an off-diagonal tile.

            const unsigned int localAtomIndex = threadIdx.x;
            unsigned int j = y*TILE_SIZE + tgx;
            localData[localAtomIndex].posq = posq[j];
            LOAD_LOCAL_PARAMETERS_FROM_GLOBAL
            localData[localAtomIndex].value = 0;
#ifdef USE_EXCLUSIONS
            excl = (excl >> tgx) | (excl << (TILE_SIZE - tgx));
#endif
            unsigned int tj = tgx;
            for (j = 0; j < TILE_SIZE; j++) {
                int atom2 = tbx+tj;
                real4 posq2 = localData[atom2].posq;
                real3 delta = make_real3(posq2.x-posq1.x, posq2.y-posq1.y, posq2.z-posq1.z);
#ifdef USE_PERIODIC
                delta.x -= floor(delta.x*invPeriodicBoxSize.x+0.5f)*periodicBoxSize.x;
                delta.y -= floor(delta.y*invPeriodicBoxSize.y+0.5f)*periodicBoxSize.y;
                delta.z -= floor(delta.z*invPeriodicBoxSize.z+0.5f)*periodicBoxSize.z;
#endif
                real r2 = delta.x*delta.x + delta.y*delta.y + delta.z*delta.z;
#ifdef USE_CUTOFF
                if (r2 < CUTOFF_SQUARED) {
#endif
                    real invR = RSQRT(r2);
                    real r = RECIP(invR);
                    LOAD_ATOM2_PARAMETERS
                    atom2 = y*TILE_SIZE+tj;
                    real tempValue1 = 0;
                    real tempValue2 = 0;
#ifdef USE_EXCLUSIONS
                    bool isExcluded = (atom1 >= NUM_ATOMS || atom2 >= NUM_ATOMS || !(excl & 0x1));
                    if (!isExcluded) {
#else
                    if (atom1 < NUM_ATOMS && atom2 < NUM_ATOMS) {
#endif
                        COMPUTE_VALUE
                    }
                    value += tempValue1;
                    localData[tbx+tj].value += tempValue2;
#ifdef USE_CUTOFF
                }
#endif
#ifdef USE_EXCLUSIONS
                excl >>= 1;
#endif
                tj = (tj + 1) & (TILE_SIZE - 1);
            }
        }

        // Write results.

        unsigned int offset = x*TILE_SIZE + tgx;
        atomicAdd(&global_value[offset], static_cast<unsigned long long>((long long) (value*0x100000000)));
        if (x != y) {
            offset = y*TILE_SIZE + tgx;
            atomicAdd(&global_value[offset], static_cast<unsigned long long>((long long) (localData[threadIdx.x].value*0x100000000)));
        }
    }

    // Second loop: tiles without exclusions, either from the neighbor list (with cutoff) or just enumerating all
    // of them (no cutoff).

#ifdef USE_CUTOFF
    unsigned int numTiles = interactionCount[0];
    int pos = warp*(numTiles > maxTiles ? NUM_BLOCKS*(NUM_BLOCKS+1)/2 : numTiles)/totalWarps;
    int end = (warp+1)*(numTiles > maxTiles ? NUM_BLOCKS*(NUM_BLOCKS+1)/2 : numTiles)/totalWarps;
#else
    int pos = warp*numTiles/totalWarps;
    int end = (warp+1)*numTiles/totalWarps;
#endif
    int skipBase = 0;
    int currentSkipIndex = tbx;
    __shared__ int atomIndices[THREAD_BLOCK_SIZE];
    __shared__ volatile int skipTiles[THREAD_BLOCK_SIZE];
    skipTiles[threadIdx.x] = -1;
    
    while (pos < end) {
        real value = 0;
        bool includeTile = true;
        
        // Extract the coordinates of this tile.
        
        unsigned int x, y;
        bool singlePeriodicCopy = false;
#ifdef USE_CUTOFF
        if (numTiles <= maxTiles) {
            ushort2 tileIndices = tiles[pos];
            x = tileIndices.x;
            real4 blockSizeX = blockSize[x];
            singlePeriodicCopy = (0.5f*periodicBoxSize.x-blockSizeX.x >= CUTOFF &&
                                  0.5f*periodicBoxSize.y-blockSizeX.y >= CUTOFF &&
                                  0.5f*periodicBoxSize.z-blockSizeX.z >= CUTOFF);
        }
        else
#endif
        {
            y = (unsigned int) floor(NUM_BLOCKS+0.5f-SQRT((NUM_BLOCKS+0.5f)*(NUM_BLOCKS+0.5f)-2*pos));
            x = (pos-y*NUM_BLOCKS+y*(y+1)/2);
            if (x < y || x >= NUM_BLOCKS) { // Occasionally happens due to roundoff error.
                y += (x < y ? -1 : 1);
                x = (pos-y*NUM_BLOCKS+y*(y+1)/2);
            }

            // Skip over tiles that have exclusions, since they were already processed.

            while (skipTiles[tbx+TILE_SIZE-1] < pos) {
                if (skipBase+tgx < NUM_TILES_WITH_EXCLUSIONS) {
                    ushort2 tile = exclusionTiles[skipBase+tgx];
                    skipTiles[threadIdx.x] = tile.x + tile.y*NUM_BLOCKS - tile.y*(tile.y+1)/2;
                }
                else
                    skipTiles[threadIdx.x] = end;
                skipBase += TILE_SIZE;            
                currentSkipIndex = tbx;
            }
            while (skipTiles[currentSkipIndex] < pos)
                currentSkipIndex++;
            includeTile = (skipTiles[currentSkipIndex] != pos);
        }
        if (includeTile) {
            unsigned int atom1 = x*TILE_SIZE + tgx;

            // Load atom data for this tile.
            
            real4 posq1 = posq[atom1];
            LOAD_ATOM1_PARAMETERS
            const unsigned int localAtomIndex = threadIdx.x;
#ifdef USE_CUTOFF
            unsigned int j = (numTiles <= maxTiles ? interactingAtoms[pos*TILE_SIZE+tgx] : y*TILE_SIZE + tgx);
#else
            unsigned int j = y*TILE_SIZE + tgx;
#endif
            atomIndices[threadIdx.x] = j;
            if (j < PADDED_NUM_ATOMS) {
                localData[localAtomIndex].posq = posq[j];
                LOAD_LOCAL_PARAMETERS_FROM_GLOBAL
                localData[localAtomIndex].value = 0;
            }
#ifdef USE_PERIODIC
            if (singlePeriodicCopy) {
                // The box is small enough that we can just translate all the atoms into a single periodic
                // box, then skip having to apply periodic boundary conditions later.

                real4 blockCenterX = blockCenter[x];
                posq1.x -= floor((posq1.x-blockCenterX.x)*invPeriodicBoxSize.x+0.5f)*periodicBoxSize.x;
                posq1.y -= floor((posq1.y-blockCenterX.y)*invPeriodicBoxSize.y+0.5f)*periodicBoxSize.y;
                posq1.z -= floor((posq1.z-blockCenterX.z)*invPeriodicBoxSize.z+0.5f)*periodicBoxSize.z;
                localData[threadIdx.x].posq.x -= floor((localData[threadIdx.x].posq.x-blockCenterX.x)*invPeriodicBoxSize.x+0.5f)*periodicBoxSize.x;
                localData[threadIdx.x].posq.y -= floor((localData[threadIdx.x].posq.y-blockCenterX.y)*invPeriodicBoxSize.y+0.5f)*periodicBoxSize.y;
                localData[threadIdx.x].posq.z -= floor((localData[threadIdx.x].posq.z-blockCenterX.z)*invPeriodicBoxSize.z+0.5f)*periodicBoxSize.z;
                unsigned int tj = tgx;
                for (unsigned int j = 0; j < TILE_SIZE; j++) {
                    int atom2 = tbx+tj;
                    real4 posq2 = localData[atom2].posq;
                    real3 delta = make_real3(posq2.x-posq1.x, posq2.y-posq1.y, posq2.z-posq1.z);
                    real r2 = delta.x*delta.x + delta.y*delta.y + delta.z*delta.z;
                    if (r2 < CUTOFF_SQUARED) {
                        real invR = RSQRT(r2);
                        real r = RECIP(invR);
                        LOAD_ATOM2_PARAMETERS
                        atom2 = atomIndices[tbx+tj];
                        real tempValue1 = 0;
                        real tempValue2 = 0;
                        if (atom1 < NUM_ATOMS && atom2 < NUM_ATOMS) {
                            COMPUTE_VALUE
                        }
                        value += tempValue1;
                        localData[tbx+tj].value += tempValue2;
                    }
                    tj = (tj + 1) & (TILE_SIZE - 1);
                }
            }
            else
#endif
            {
                // We need to apply periodic boundary conditions separately for each interaction.

                unsigned int tj = tgx;
                for (unsigned int j = 0; j < TILE_SIZE; j++) {
                    int atom2 = tbx+tj;
                    real4 posq2 = localData[atom2].posq;
                    real3 delta = make_real3(posq2.x-posq1.x, posq2.y-posq1.y, posq2.z-posq1.z);
#ifdef USE_PERIODIC
                    delta.x -= floor(delta.x*invPeriodicBoxSize.x+0.5f)*periodicBoxSize.x;
                    delta.y -= floor(delta.y*invPeriodicBoxSize.y+0.5f)*periodicBoxSize.y;
                    delta.z -= floor(delta.z*invPeriodicBoxSize.z+0.5f)*periodicBoxSize.z;
#endif
                    real r2 = delta.x*delta.x + delta.y*delta.y + delta.z*delta.z;
#ifdef USE_CUTOFF
                    if (r2 < CUTOFF_SQUARED) {
#endif
                        real invR = RSQRT(r2);
                        real r = RECIP(invR);
                        LOAD_ATOM2_PARAMETERS
                        atom2 = atomIndices[tbx+tj];
                        real tempValue1 = 0;
                        real tempValue2 = 0;
                        if (atom1 < NUM_ATOMS && atom2 < NUM_ATOMS) {
                            COMPUTE_VALUE
                        }
                        value += tempValue1;
                        localData[tbx+tj].value += tempValue2;
#ifdef USE_CUTOFF
                    }
#endif
                    tj = (tj + 1) & (TILE_SIZE - 1);
                }
            }
        
            // Write results.

            atomicAdd(&global_value[atom1], static_cast<unsigned long long>((long long) (value*0x100000000)));
#ifdef USE_CUTOFF
            unsigned int atom2 = atomIndices[threadIdx.x];
#else
            unsigned int atom2 = y*TILE_SIZE + tgx;
#endif
            if (atom2 < PADDED_NUM_ATOMS)
                atomicAdd(&global_value[atom2], static_cast<unsigned long long>((long long) (localData[threadIdx.x].value*0x100000000)));
        }
        pos++;
    }
}
