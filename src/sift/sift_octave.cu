#include <sstream>
#include <sys/stat.h>
#include <new> // for placement new

#include "sift_pyramid.h"
#include "sift_constants.h"
#include "debug_macros.h"
#include "clamp.h"
#include "write_plane_2d.h"
#include "sift_octave.h"

// #define PYRAMID_PRINT_DEBUG 0
#undef PRINT_WITH_ORIENTATION

using namespace std;

namespace popart {

/*************************************************************
 * Octave
 *************************************************************/

Octave::Octave( )
    : _data(0)
    , _h_extrema_mgmt(0)
    , _d_extrema_mgmt(0)
    , _h_extrema(0)
    , _d_extrema(0)
    , _d_desc(0)
    , _h_desc(0)
{ }


void Octave::alloc( int width, int height, int levels, int gauss_group )
{
    _w           = width;
    _h           = height;
    _levels      = levels;
    _gauss_group = gauss_group;

#if (PYRAMID_PRINT_DEBUG==1)
    printf("    correcting to width %u, height %u\n", _width, _height );
#endif // (PYRAMID_PRINT_DEBUG==1)

    alloc_data_planes( );
    alloc_data_tex( );

    alloc_interm_plane( );
    alloc_interm_tex( );

    alloc_dog_array( );
    alloc_dog_tex( );

    alloc_extrema_mgmt( );
    alloc_extrema( );

    alloc_streams( );
    alloc_events( );

    _d_desc = new Descriptor*[_levels];
    _h_desc = new Descriptor*[_levels];

    for( int l=0; l<_levels; l++ ) {
        int sz = h_max_orientations;
        if( sz == 0 ) {
            _d_desc[l] = 0;
            _h_desc[l] = 0;
        } else {
            _d_desc[l] = popart::cuda::malloc_devT<Descriptor>( sz, __FILE__, __LINE__ );
            _h_desc[l] = popart::cuda::malloc_hstT<Descriptor>( sz, __FILE__, __LINE__ );
        }
    }
}

void Octave::free( )
{
    for( int i=0; i<_levels; i++ ) {
        if( _h_desc && _h_desc[i] ) cudaFreeHost( _h_desc[i] );
        if( _d_desc && _d_desc[i] ) cudaFree(     _d_desc[i] );
    }
    delete [] _d_desc;
    delete [] _h_desc;

    free_events( );
    free_streams( );

    free_extrema( );
    free_extrema_mgmt( );

    free_dog_tex( );
    free_dog_array( );

    free_interm_tex( );
    free_interm_plane( );

    free_data_tex( );
    free_data_planes( );
}

void Octave::reset_extrema_mgmt( )
{
    cudaStream_t stream = _streams[0];
    cudaEvent_t  ev     = _extrema_done[0];

    memset( _h_extrema_mgmt, 0, _levels * sizeof(int) );
    popcuda_memset_async( _d_extrema_mgmt, 0, _levels * sizeof(int), stream );
    popcuda_memset_async( _d_extrema_num_blocks, 0, _levels * sizeof(int), stream );
    popcuda_memset_async( _d_orientation_num_blocks, 0, _levels * sizeof(int), stream );

    cudaEventRecord( ev, stream );
}

void Octave::readExtremaCount( )
{
    assert( _h_extrema_mgmt );
    assert( _d_extrema_mgmt );
    popcuda_memcpy_async( _h_extrema_mgmt,
                          _d_extrema_mgmt,
                          _levels * sizeof(int),
                          cudaMemcpyDeviceToHost,
                          _streams[0] );
}

int Octave::getExtremaCount( ) const
{
    int ct = 0;
    for( uint32_t i=1; i<_levels-1; i++ ) {
        ct += _h_extrema_mgmt[i];
    }
    return ct;
}

int Octave::getExtremaCount( uint32_t level ) const
{
    if( level < 1 )         return 0;
    if( level > _levels-2 ) return 0;
    return _h_extrema_mgmt[level];
}

void Octave::downloadDescriptor( )
{
    for( uint32_t l=0; l<_levels; l++ ) {
        int sz = _h_extrema_mgmt[l];
        if( sz != 0 ) {
            if( _h_extrema[l] == 0 ) continue;

            popcuda_memcpy_async( _h_desc[l],
                                  _d_desc[l],
                                  sz * sizeof(Descriptor),
                                  cudaMemcpyDeviceToHost,
                                  0 );
            popcuda_memcpy_async( _h_extrema[l],
                                  _d_extrema[l],
                                  sz * sizeof(Extremum),
                                  cudaMemcpyDeviceToHost,
                                  0 );
        }
    }

    cudaDeviceSynchronize( );
}

void Octave::writeDescriptor( ostream& ostr, float downsampling_factor, bool really )
{
    for( uint32_t l=0; l<_levels; l++ ) {
        if( _h_extrema[l] == 0 ) continue;

        Extremum* cand = _h_extrema[l];

        Descriptor* desc = _h_desc[l];

        int sz = _h_extrema_mgmt[l];
        for( int s=0; s<sz; s++ ) {
            const float reduce = downsampling_factor;

            float xpos  = cand[s].xpos * pow( 2.0, _debug_octave_id + reduce );
            float ypos  = cand[s].ypos * pow( 2.0, _debug_octave_id + reduce );
            float sigma = cand[s].sigma * pow( 2.0, _debug_octave_id + reduce );
            float ori = cand[s].orientation;
            ori = ori / M_PI2 * 360;
            if( ori < 0 ) ori += 360;
            // ori = 360.0f - ( ori / M_PI2 * 360 );
            // if( ori > 360.0f ) ori -= 360.0f;

#ifdef PRINT_WITH_ORIENTATION
            ostr << setprecision(5)
                 << xpos << " "
                 << ypos << " "
                 << sigma << " "
                 << ori << " ";
#else
            ostr << setprecision(5)
                 << xpos << " " << ypos << " "
                 << 1.0f / ( sigma * sigma )
                 << " 0 "
                 << 1.0f / ( sigma * sigma ) << " ";
#endif
            if( really ) {
                for( int i=0; i<128; i++ ) {
                    ostr << desc[s].features[i] << " ";
                }
            }
            ostr << endl;
        }
    }
}

Descriptor* Octave::getDescriptors( uint32_t level )
{
    return _d_desc[level];
}

/*************************************************************
 * Debug output: write an octave/level to disk as PGM
 *************************************************************/

void Octave::download_and_save_array( const char* basename, uint32_t octave, uint32_t level )
{
    // cerr << "Calling " << __FUNCTION__ << " for octave " << octave << endl;

    if( level >= _levels ) {
        // cerr << "Level " << level << " does not exist in Octave " << octave << endl;
        return;
    }

    struct stat st = {0};

#if 1
    {
        if (stat("dir-octave", &st) == -1) {
            mkdir("dir-octave", 0700);
        }

        ostringstream ostr;
        ostr << "dir-octave/" << basename << "-o-" << octave << "-l-" << level << ".pgm";
        popart::write_plane2Dunscaled( ostr.str().c_str(), true, getData(level) );

        if (stat("dir-octave-dump", &st) == -1) {
            mkdir("dir-octave-dump", 0700);
        }

        ostringstream ostr2;
        ostr2 << "dir-octave-dump/" << basename << "-o-" << octave << "-l-" << level << ".pgm";
        popart::dump_plane2Dfloat( ostr2.str().c_str(), true, getData(level) );

        if( level == 0 ) {
            int width  = getData(level).getWidth();
            int height = getData(level).getHeight();

            Plane2D_float hostPlane_f;
            hostPlane_f.allocHost( width, height, CudaAllocated );
            hostPlane_f.memcpyFromDevice( getData(level) );

            uint32_t total_ct = 0;

            readExtremaCount( );
            cudaDeviceSynchronize( );
            for( uint32_t l=0; l<_levels; l++ ) {
                uint32_t ct = getExtremaCount( l );
                if( ct > 0 ) {
                    total_ct += ct;

                    Extremum* cand = new Extremum[ct];

                    popcuda_memcpy_sync( cand,
                                         _d_extrema[l],
                                         ct * sizeof(Extremum),
                                         cudaMemcpyDeviceToHost );
                    for( uint32_t i=0; i<ct; i++ ) {
                        int32_t x = roundf( cand[i].xpos );
                        int32_t y = roundf( cand[i].ypos );
                        // cerr << "(" << x << "," << y << ") scale " << cand[i].sigma << " orient " << cand[i].orientation << endl;
                        for( int32_t j=-4; j<=4; j++ ) {
                            hostPlane_f.ptr( clamp(y+j,height) )[ clamp(x,  width) ] = 255;
                            hostPlane_f.ptr( clamp(y,  height) )[ clamp(x+j,width) ] = 255;
                        }
                    }

                    delete [] cand;
                }
            }

            if( total_ct > 0 ) {
                if (stat("dir-feat", &st) == -1) {
                    mkdir("dir-feat", 0700);
                }

                if (stat("dir-feat-txt", &st) == -1) {
                    mkdir("dir-feat-txt", 0700);
                }


                ostringstream ostr;
                ostr << "dir-feat/" << basename << "-o-" << octave << "-l-" << level << ".pgm";
                ostringstream ostr2;
                ostr2 << "dir-feat-txt/" << basename << "-o-" << octave << "-l-" << level << ".txt";
        #if 0
                ofstream of( ostr.str().c_str() );
                // cerr << "Writing " << ostr.str() << endl;
                of << "P5" << endl
                   << width << " " << height << endl
                   << "255" << endl;
                of.write( (char*)hostPlane_c.data, hostPlane_c.getByteSize() );
                of.close();
        #endif

                popart::write_plane2D( ostr.str().c_str(), false, hostPlane_f );
                popart::write_plane2Dunscaled( ostr2.str().c_str(), false, hostPlane_f );
            }

            hostPlane_f.freeHost( CudaAllocated );
        }
    }
#endif
#if 1
    if( level == _levels-1 ) {
        cudaError_t err;
        int width  = getData(0).getWidth();
        int height = getData(0).getHeight();

        if (stat("dir-dog", &st) == -1) {
            mkdir("dir-dog", 0700);
        }

        if (stat("dir-dog-txt", &st) == -1) {
            mkdir("dir-dog-txt", 0700);
        }

        if (stat("dir-dog-dump", &st) == -1) {
            mkdir("dir-dog-dump", 0700);
        }

        float* array;
        POP_CUDA_MALLOC_HOST( &array, width * height * (_levels-1) * sizeof(float) );

        cudaMemcpy3DParms s = { 0 };
        s.srcArray = _dog_3d;
        s.dstPtr = make_cudaPitchedPtr( array, width*sizeof(float), width, height );
        s.extent = make_cudaExtent( width, height, _levels-1 );
        s.kind = cudaMemcpyDeviceToHost;
        err = cudaMemcpy3D( &s );
        POP_CUDA_FATAL_TEST( err, "cudaMemcpy3D failed: " ); \

        for( int l=0; l<_levels-1; l++ ) {
            Plane2D_float p( width, height, &array[l*width*height], width*sizeof(float) );

            ostringstream ostr;
            ostr << "dir-dog/d-" << basename << "-o-" << octave << "-l-" << l << ".pgm";
            // cerr << "Writing " << ostr.str() << endl;
            popart::write_plane2D( ostr.str().c_str(), true, p );

            ostringstream pstr;
            pstr << "dir-dog-txt/d-" << basename << "-o-" << octave << "-l-" << l << ".txt";
            popart::write_plane2Dunscaled( pstr.str().c_str(), true, p, 127 );

            ostringstream qstr;
            qstr << "dir-dog-dump/d-" << basename << "-o-" << octave << "-l-" << l << ".txt";
            popart::dump_plane2Dfloat( qstr.str().c_str(), true, p );
        }

        POP_CUDA_FREE_HOST( array );
    }
#endif
}

void Octave::alloc_data_planes( )
{
    cudaError_t err;
    void*       ptr;
    size_t      pitch;

    _data = new Plane2D_float[_levels];

    err = cudaMallocPitch( &ptr, &pitch, _w * sizeof(float), _h * _levels );
    POP_CUDA_FATAL_TEST( err, "Cannot allocate data CUDA memory: " );
    for( int i=0; i<_levels; i++ ) {
        _data[i] = Plane2D_float( _w,
                                  _h,
                                  (float*)( (intptr_t)ptr + i*(pitch*_h) ),
                                  pitch );
    }
}

void Octave::free_data_planes( )
{
    POP_CUDA_FREE( _data[0].data );
    delete [] _data;
}

void Octave::alloc_data_tex( )
{
    cudaError_t err;

    _data_tex = new cudaTextureObject_t[_levels];

    cudaTextureDesc      data_tex_desc;
    cudaResourceDesc     data_res_desc;

    memset( &data_tex_desc, 0, sizeof(cudaTextureDesc) );
    data_tex_desc.normalizedCoords = 0; // addressed (x,y) in [width,height]
    data_tex_desc.addressMode[0]   = cudaAddressModeClamp;
    data_tex_desc.addressMode[1]   = cudaAddressModeClamp;
    data_tex_desc.addressMode[2]   = cudaAddressModeClamp;
    data_tex_desc.readMode         = cudaReadModeElementType; // read as float
    // data_tex_desc.filterMode       = cudaFilterModePoint; // no interpolation
    data_tex_desc.filterMode       = cudaFilterModeLinear; // bilinear interpolation

    memset( &data_res_desc, 0, sizeof(cudaResourceDesc) );
    data_res_desc.resType                  = cudaResourceTypePitch2D;
    data_res_desc.res.pitch2D.desc.f       = cudaChannelFormatKindFloat;
    data_res_desc.res.pitch2D.desc.x       = 32;
    data_res_desc.res.pitch2D.desc.y       = 0;
    data_res_desc.res.pitch2D.desc.z       = 0;
    data_res_desc.res.pitch2D.desc.w       = 0;
    for( int i=0; i<_levels; i++ ) {
        data_res_desc.res.pitch2D.devPtr       = _data[i].data;
        data_res_desc.res.pitch2D.pitchInBytes = _data[i].step;
        data_res_desc.res.pitch2D.width        = _data[i].getCols();
        data_res_desc.res.pitch2D.height       = _data[i].getRows();

        err = cudaCreateTextureObject( &_data_tex[i],
                                       &data_res_desc,
                                       &data_tex_desc, 0 );
        POP_CUDA_FATAL_TEST( err, "Could not create texture object: " );
    }
}

void Octave::free_data_tex( )
{
    cudaError_t err;

    for( int i=0; i<_levels; i++ ) {
        err = cudaDestroyTextureObject( _data_tex[i] );
        POP_CUDA_FATAL_TEST( err, "Could not destroy texture object: " );
    }

    delete [] _data_tex;
}

void Octave::alloc_interm_plane( )
{
#if 0
    /*
     * no longer meaningful, and leads to bugs
     */

    /* Usually we alloc only one plane's worth of floats.
     * When we group gauss filters, we need #groupsize intermediate
     * planes. For efficiency, we use only a single allocation,
     * but if we use interpolation, we should better have a buffer
     * filled with zeros between the sections of the plane.
     * We give this buffer 4 rows.
     */
    _intermediate_data.allocDev( _w, _gauss_group * ( _h + 4 ) );
#endif
    _intermediate_data.allocDev( _w, _h );
}

void Octave::free_interm_plane( )
{
    _intermediate_data.freeDev( );
}

void Octave::alloc_interm_tex( )
{
    cudaError_t err;

    cudaTextureDesc      data_tex_desc;
    cudaResourceDesc     data_res_desc;

    memset( &data_tex_desc, 0, sizeof(cudaTextureDesc) );
    data_tex_desc.normalizedCoords = 0; // addressed (x,y) in [width,height]
    data_tex_desc.addressMode[0]   = cudaAddressModeClamp;
    data_tex_desc.addressMode[1]   = cudaAddressModeClamp;
    data_tex_desc.addressMode[2]   = cudaAddressModeClamp;
    data_tex_desc.readMode         = cudaReadModeElementType; // read as float
#ifdef GAUSS_INTERM_FILTER_MODE_POINT
    data_tex_desc.filterMode       = cudaFilterModePoint; // no interpolation
#else // not GAUSS_INTERM_FILTER_MODE_POINT
    data_tex_desc.filterMode       = cudaFilterModeLinear; // bilinear interpolation
#endif // not GAUSS_INTERM_FILTER_MODE_POINT

    memset( &data_res_desc, 0, sizeof(cudaResourceDesc) );
    data_res_desc.resType                  = cudaResourceTypePitch2D;
    data_res_desc.res.pitch2D.desc.f       = cudaChannelFormatKindFloat;
    data_res_desc.res.pitch2D.desc.x       = 32;
    data_res_desc.res.pitch2D.desc.y       = 0;
    data_res_desc.res.pitch2D.desc.z       = 0;
    data_res_desc.res.pitch2D.desc.w       = 0;

    data_res_desc.res.pitch2D.devPtr       = _intermediate_data.data;
    data_res_desc.res.pitch2D.pitchInBytes = _intermediate_data.step;
    data_res_desc.res.pitch2D.width        = _intermediate_data.getCols();
    data_res_desc.res.pitch2D.height       = _intermediate_data.getRows();
    // cerr << "Allocating texture for octave " << _debug_octave_id << " with width " << data_res_desc.res.pitch2D.width << " height " << data_res_desc.res.pitch2D.height << endl;

    err = cudaCreateTextureObject( &_interm_data_tex,
                                   &data_res_desc,
                                   &data_tex_desc, 0 );
    POP_CUDA_FATAL_TEST( err, "Could not create texture object: " );
}

void Octave::free_interm_tex( )
{
    cudaError_t err;

    err = cudaDestroyTextureObject( _interm_data_tex );
    POP_CUDA_FATAL_TEST( err, "Could not destroy texture object: " );
}

void Octave::alloc_dog_array( )
{
    cudaError_t err;

    _dog_3d_desc.f = cudaChannelFormatKindFloat;
    _dog_3d_desc.x = 32;
    _dog_3d_desc.y = 0;
    _dog_3d_desc.z = 0;
    _dog_3d_desc.w = 0;

    _dog_3d_ext.width  = _w; // for cudaMalloc3DArray, width in elements
    _dog_3d_ext.height = _h;
    _dog_3d_ext.depth  = _levels - 1;

    err = cudaMalloc3DArray( &_dog_3d,
                             &_dog_3d_desc,
                             _dog_3d_ext,
                             cudaArrayLayered | cudaArraySurfaceLoadStore );
    POP_CUDA_FATAL_TEST( err, "Could not allocate 3D DoG array: " );
}

void Octave::free_dog_array( )
{
    cudaError_t err;

    err = cudaFreeArray( _dog_3d );
    POP_CUDA_FATAL_TEST( err, "Could not free 3D DoG array: " );
}

void Octave::alloc_dog_tex( )
{
    cudaError_t err;

    cudaResourceDesc dog_res_desc;
    dog_res_desc.resType         = cudaResourceTypeArray;
    dog_res_desc.res.array.array = _dog_3d;

    err = cudaCreateSurfaceObject( &_dog_3d_surf, &dog_res_desc );
    POP_CUDA_FATAL_TEST( err, "Could not create DoG surface: " );

    cudaTextureDesc      dog_tex_desc;
    memset( &dog_tex_desc, 0, sizeof(cudaTextureDesc) );
    dog_tex_desc.normalizedCoords = 0; // addressed (x,y) in [width,height]
    dog_tex_desc.addressMode[0]   = cudaAddressModeClamp;
    dog_tex_desc.addressMode[1]   = cudaAddressModeClamp;
    dog_tex_desc.addressMode[2]   = cudaAddressModeClamp;
    dog_tex_desc.readMode         = cudaReadModeElementType; // read as float
    dog_tex_desc.filterMode       = cudaFilterModePoint; // no interpolation

    // cudaResourceView dog_tex_view;
    // memset( &dog_tex_view, 0, sizeof(cudaResourceView) );
    // dog_tex_view.format     = cudaResViewFormatFloat1;
    // dog_tex_view.width      = width;
    // dog_tex_view.height     = height;
    // dog_tex_view.depth      = 1;
    // dog_tex_view.firstLayer = 0;
    // dog_tex_view.lastLayer  = _levels - 1;

    err = cudaCreateTextureObject( &_dog_3d_tex, &dog_res_desc, &dog_tex_desc, 0 );
    POP_CUDA_FATAL_TEST( err, "Could not create DoG texture: " );
}

void Octave::free_dog_tex( )
{
    cudaError_t err;

    err = cudaDestroyTextureObject( _dog_3d_tex );
    POP_CUDA_FATAL_TEST( err, "Could not destroy DoG texture: " );

    err = cudaDestroySurfaceObject( _dog_3d_surf );
    POP_CUDA_FATAL_TEST( err, "Could not destroy DoG surface: " );
}

void Octave::alloc_extrema_mgmt( )
{
    _h_extrema_mgmt           = popart::cuda::malloc_hstT<int>( _levels, __FILE__, __LINE__ );
    _d_extrema_mgmt           = popart::cuda::malloc_devT<int>( _levels, __FILE__, __LINE__ );
    _d_extrema_num_blocks     = popart::cuda::malloc_devT<int>( _levels, __FILE__, __LINE__ );
    _d_orientation_num_blocks = popart::cuda::malloc_devT<int>( _levels, __FILE__, __LINE__ );
}

void Octave::free_extrema_mgmt( )
{
    cudaFree( _d_orientation_num_blocks );
    cudaFree( _d_extrema_num_blocks );
    cudaFree( _d_extrema_mgmt );
    cudaFreeHost( _h_extrema_mgmt );
}

void Octave::alloc_extrema( )
{
    _d_extrema = new Extremum*[ _levels ];
    _h_extrema = new Extremum*[ _levels ];

    _h_extrema[0] = 0;
    _h_extrema[_levels-1] = 0;
    _d_extrema[0] = 0;
    _d_extrema[_levels-1] = 0;

    int objects_per_level = h_max_orientations;
    int levels            = _levels - 2;

    Extremum* d = popart::cuda::malloc_devT<Extremum>( levels * objects_per_level, __FILE__, __LINE__ );
    Extremum* h = popart::cuda::malloc_hstT<Extremum>( levels * objects_per_level, __FILE__, __LINE__ );

    for( uint32_t i=1; i<_levels-1; i++ ) {
        const int offset = i-1;
        _d_extrema[i] = &d[offset*objects_per_level];
        _h_extrema[i] = &h[offset*objects_per_level];
    }
}

void Octave::free_extrema( )
{
    cudaFreeHost( _h_extrema[1] );
    cudaFree(     _d_extrema[1] );
    delete [] _d_extrema;
    delete [] _h_extrema;
}

void Octave::alloc_streams( )
{
    _streams = new cudaStream_t[_levels];

    for( int i=0; i<_levels; i++ ) {
        _streams[i]    = popart::cuda::stream_create( __FILE__, __LINE__ );
    }
}

void Octave::free_streams( )
{
    for( int i=0; i<_levels; i++ ) {
        popart::cuda::stream_destroy( _streams[i], __FILE__, __LINE__ );
    }
    delete [] _streams;
}

void Octave::alloc_events( )
{
    _gauss_done   = new cudaEvent_t[_levels];
    _dog_done     = new cudaEvent_t[_levels];
    _extrema_done = new cudaEvent_t[_levels];
    for( int i=0; i<_levels; i++ ) {
        _gauss_done[i]   = popart::cuda::event_create( __FILE__, __LINE__ );
        _dog_done[i]     = popart::cuda::event_create( __FILE__, __LINE__ );
        _extrema_done[i] = popart::cuda::event_create( __FILE__, __LINE__ );
    }
}

void Octave::free_events( )
{
    for( int i=0; i<_levels; i++ ) {
        popart::cuda::event_destroy( _gauss_done[i],   __FILE__, __LINE__ );
        popart::cuda::event_destroy( _dog_done[i],     __FILE__, __LINE__ );
        popart::cuda::event_destroy( _extrema_done[i], __FILE__, __LINE__ );
    }

    delete [] _gauss_done;
    delete [] _dog_done;
    delete [] _extrema_done;
}

void Octave::downloadToVector(uint32_t level, std::vector<Extremum> &candidates, std::vector<Descriptor> &descriptors)
{

    readExtremaCount( ); // CHECK
    cudaDeviceSynchronize( );
    uint32_t ct = getExtremaCount( level );
    if( ct > 0 ) {
        candidates.resize(ct);        
        popcuda_memcpy_sync( &candidates[0],
                            _d_extrema[level],
                            ct * sizeof(Extremum),
                            cudaMemcpyDeviceToHost );
        descriptors.resize(ct);        
        popcuda_memcpy_sync( &descriptors[0],
                        _d_desc[level],
                        ct * sizeof(Descriptor),
                        cudaMemcpyDeviceToHost );
    }
}

} // namespace popart
