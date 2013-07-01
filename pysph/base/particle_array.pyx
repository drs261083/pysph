"""
Represents a collection of particles.

**Classes**
 
 - ParticleArray - class to represent an array of particles.

**Default Property Names**

 - X coordinate - 'x'
 - Y coordinate - 'y'
 - Z coordinate - 'z'
 - Particle X Velocity - 'u'
 - Particle Y Velocity - 'v'
 - Particle Z Velocity - 'w'
 - Particle mass - 'm'
 - Particle density - 'rho'
 - Particle Interaction Radius - 'h'

The default property names is not enforced here. It is enforced by having
default values to property names in various constructors.

"""
cdef extern from "string.h":
    int strcmp(char *s1, char *s2)

# logging imports
import logging
logger = logging.getLogger()

# numpy imports
cimport numpy
import numpy

# PyZoltan imports
from pyzoltan.core.carray cimport *

# Local imports
from cpython cimport PyObject
from cpython cimport *
from cython cimport *

# Parallel imports
try:
    from mpi4py import MPI
except ImportError:
    MPI = None

# Maximum value of an unsigned int
cdef extern from "limits.h":
    cdef unsigned int UINT_MAX

_UINT_MAX = UINT_MAX

# Declares various tags for particles, and functions to check them.

# Note that these tags are the ones set in the 'tag' property of the
# particles, in a particle array. To define additional discrete
# properties, one can add another integer property to the particles in
# the particle array while creating them.

# These tags could be considered as 'system tags' used internally to
# distinguish among different kinds of particles. If more tags are
# needed for a particular application, add them as mentioned above.

# The is_* functions defined below are to be used in Python for tests
# etc. Cython modules can directly use the enum name.

cpdef bint is_local(int tag):
    return tag == Local

cpdef bint is_remote(int tag):
    return tag == Remote

cpdef bint is_ghost(int tag):
    return tag == Ghost

cpdef int get_local_tag():
    return Local

cpdef int get_remote_tag():
    return Remote

cpdef int get_ghost_tag():
    return Ghost

cdef class ParticleArray:
    """
    Class to represent a collection of particles.

    **Member variables**
     - name - name of this particle array.
     - properties - for every property, gives the index into the list where the
       property array is found.
     - property_arrays - list of arrays, one for each property.
       for internal calculations.
     - is_dirty - indicates if the particle positions have changed.
     - standard_name_map - a map from a few standard property names to the
       actual names used in this particle array.

    **Notes**
     - the property 'tag' is always the 0th property.
    
    **Issues**
     - Decision on standard_name_map to be made.

    """
    ######################################################################
    # `object` interface
    ######################################################################
    def __cinit__(self, str name='', default_particle_tag=Local,
                  cl_precision = 'double', constants={},
                  *args, **props):
        """ Constructor

        Parameters
        ----------

        name : str 
            name of this particle array.

        cl_precision : {'single', 'double'}
            Set the precision to use for OpenCL.

        props : dict 
            dictionary of properties for every particle in this array

        """
        self.properties = {'tag':IntArray(0),'pid':IntArray(0), 'gid':UIntArray(0)}
        self.default_values = {'tag':default_particle_tag, 'pid':0}
        
        self.constants = {}
        self.constants.update(constants)

        # set the default time
        self.time = 0.0

        self.name = name
        self.is_dirty = True
        self.indices_invalid = True
        
        self.cl_precision = cl_precision

        self.queue = object()
        self.device = object()
        self.context = object()

        self.pa_buf_host = object()
        self.pa_tag_host = object()
        self.pa_buf_device = object()
        self.pa_tag_device = object()
       
        self.cl_properties = {}
        self.cl_setup_done=False

        if props:
            self.initialize(**props)

    def __getattr__(self, name):
        """ Convenience, to access particle property arrays as an attribute
        
        A numpy array is returned. Look at the get() functions documentation for
        care on using this numpy array.

        """
        keys = self.properties.keys()
        if name in keys:
            return self._get_real_particle_prop(name)
        elif name in self.constants:
            return self.constants[name]
        else:
            msg = """ ParticleArray %s has no property %s """%(self.name,
                                                               name)
            raise AttributeError(msg)

    def __setattr__(self, name, value):
        """ Convenience, to set particle property arrays as an attribute """
        keys = self.properties.keys()
        if name in keys:
            self.set(**{name:value})
        elif name in self.constants:
            self.constants[name] = value
        else:
            raise AttributeError, 'property %s not found'%(name)

    def __reduce__(self):
        """ Implemented to facilitate pickling of extension types """
        d = {}
        d['name'] = self.name
        d['constants'] = self.constants
        props = {}
        default_values = {}

        for prop, arr in self.properties.iteritems():
            pinfo = {}
            pinfo['name'] = prop            
            pinfo['type'] = arr.get_c_type()
            pinfo['data'] = arr.get_npy_array()
            pinfo['default'] = self.default_values[prop]
            props[prop] = pinfo
        
        d['properties'] = props

        return (ParticleArray, (), d)

    def __setstate__(self, d):
        """ Load the particle array object from the saved dictionary """
        self.properties = {}
        self.property_arrays = []
        self.default_values = {}
        self.is_dirty = True
        self.indices_invalid = True
        self.num_real_particles = 0

        self.name = d['name']
        props = d['properties']
        self.constants = d['constants']
        for prop in props:
            self.add_property(props[prop])
        self.num_real_particles = numpy.sum(props['tag']['data']==Local)
        
    ######################################################################
    # `Public` interface
    ######################################################################
    cpdef set_dirty(self, bint value):
        """ Set the is_dirty variable to given value """
        self.is_dirty = value

    cpdef set_indices_invalid(self, bint value):
        """ Set the indices_invalid to the given value """
        self.indices_invalid = value

    cpdef has_array(self, str arr_name):
        """ Returns true if the array arr_name is present """
        return self.properties.has_key(arr_name)

    def clear(self):
        """ Clear all data held by this array """
        self.properties = {'tag':IntArray(0), 'pid':IntArray(0)}
        tag_def_values = self.default_values['tag']
        self.default_values.clear()
        self.default_values = {'tag':tag_def_values,'pid':0}
        
        self.is_dirty = True
        self.indices_invalid = True

    cpdef set_time(self, double time):
        self.time = time

    cpdef double get_time(self):
        return self.time

    cpdef set_name(self, str name):
        self.name = name

    def initialize(self, **props):
        """ Initialize the particle array with the given props

        **Parameters**

         - props - dictionary containing various property arrays. All these
           arrays are expected to be numpy arrays or objects that can be
           converted to numpy arrays.

        **Notes**

         - This will clear any existing data.
         - As a rule internal arrays will always be either long or double
           arrays. 

        **Helper Functions**

         - _create_c_array_from_npy_array

        """
        cdef int nprop, nparticles
        cdef bint tag_present = False
        cdef numpy.ndarray a, arr, npyarr
        cdef IntArray tagarr
        cdef str prop

        self.clear()

        nprop = len(props)

        if nprop == 0:
            return 

        # add the properties
        for prop in props.keys():
            prop_info = props[prop]
            prop_info['name'] = prop
            self.add_property(prop_info)
            
        self.align_particles()

    cpdef int get_number_of_particles(self):
        """ Return the number of particles """
        if len(self.properties.values()) > 0:
            prop0 = self.properties.values()[0]
            return prop0.length
        else:
            return 0

    cpdef remove_particles(self, BaseArray index_list):
        """ Remove particles whose indices are given in index_list.

        We repeatedly interchange the values of the last element and values from
        the index_list and reduce the size of the array by one. This is done for
        every property that is being maintained.
    
        **Parameters**
        
         - index_list - an array of indices, this array should be a LongArray.

        **Algorithm**::
        
         if index_list.length > number of particles
             raise ValueError

         sorted_indices <- index_list sorted in ascending order.
        
         for every every array in property_array
             array.remove(sorted_indices)

        """
        cdef str msg
        cdef numpy.ndarray sorted_indices
        cdef BaseArray prop_array
        cdef int num_arrays, i
        cdef list property_arrays

        if index_list.length > self.get_number_of_particles():
            msg = 'Number of particles to be removed is greater than'
            msg += 'number of particles in array'
            raise ValueError, msg
        
        sorted_indices = numpy.sort(index_list.get_npy_array())
        num_arrays = len(self.properties.keys())

        property_arrays = self.properties.values()
        
        for i in range(num_arrays):
            prop_array = property_arrays[i]
            prop_array.remove(sorted_indices, 1)

        if index_list.length > 0:
            self.align_particles()
            self.is_dirty = True
            self.indices_invalid = True
    
    cpdef remove_tagged_particles(self, int tag):
        """ Remove particles that have the given tag.

        **Parameters**

         - tag - the type of particles that need to be removed.

        """
        cdef LongArray indices = LongArray()
        cdef IntArray tag_array = self.properties['tag']
        cdef int *tagarrptr = tag_array.get_data_ptr()
        cdef int i
        
        # find the indices of the particles to be removed.
        for i in range(tag_array.length):
            if tagarrptr[i] == tag:
                indices.append(i)

        # remove the particles.
        self.remove_particles(indices)

    def add_particles(self, **particle_props):
        """
        Add particles in particle_array to self.
    
        **Parameters**

         - particle_props - a dictionary containing numpy arrays for various
           particle properties.
         
        **Notes**
         
         - all properties should have same length arrays.
         - all properties should already be present in this particles array.
           if new properties are seen, an exception will be raised.
           properties.

        **Issues**

         - should the input parameter type be changed ?

        """
        cdef int num_extra_particles, old_num_particles, new_num_particles
        cdef str prop
        cdef BaseArray arr
        cdef numpy.ndarray s_arr, nparr
        
        if len(particle_props) == 0:
            return 0

        # check if the input properties are valid.
        for prop in particle_props.keys():
            self._check_property(prop)

        num_extra_particles = len(particle_props.values()[0])
        old_num_particles = self.get_number_of_particles()
        new_num_particles = num_extra_particles + old_num_particles

        for prop in self.properties:
            arr = <BaseArray>PyDict_GetItem(self.properties, prop)

            if PyDict_Contains(particle_props, prop)== 1:
                d_type = arr.get_npy_array().dtype
                s_arr = numpy.asarray(particle_props[prop], dtype=d_type)
                arr.extend(s_arr)
            else:
                arr.resize(new_num_particles)
                # set the properties of the new particles to the default ones.
                nparr = arr.get_npy_array()
                nparr[old_num_particles:] = self.default_values[prop]
        
        if num_extra_particles > 0:
            # make sure particles are aligned properly.
            self.align_particles()
            self.is_dirty = True
            
        return 0

    cpdef int append_parray(self, ParticleArray parray):
        """ Add particles from a particle array

        properties that are not there in self will be added
        """
        if parray.get_number_of_particles() == 0:
            return 0
        
        cdef int num_extra_particles = parray.get_number_of_particles()
        cdef int old_num_particles = self.get_number_of_particles()
        cdef int new_num_particles = num_extra_particles + old_num_particles
        cdef str prop_name
        cdef BaseArray arr, source, dest
        cdef numpy.ndarray nparr_dest, nparr_source
        
        # extend current arrays by the required number of particles
        self.extend(num_extra_particles)
        
        for prop_name in parray.properties.keys():
            if PyDict_Contains(self.properties, prop_name):
                arr = <BaseArray>PyDict_GetItem(self.properties, prop_name)
            else:
                arr = None
                
            if arr is not None:
                source = <BaseArray>PyDict_GetItem(parray.properties, prop_name)
                nparr_source = source.get_npy_array()
                nparr_dest = arr.get_npy_array()
                nparr_dest[old_num_particles:] = nparr_source
            else:
                # meaning this property is not there in self.
                self.add_property({'name':prop_name,
                        'default':parray.default_values[prop_name],
                        'type':parray.properties[prop_name].get_c_type()})
                # now add the values to the end of the created array
                dest = <BaseArray>PyDict_GetItem(self.properties, prop_name)
                nparr_dest = dest.get_npy_array()
                source = <BaseArray>PyDict_GetItem(parray.properties, prop_name)
                nparr_source = source.get_npy_array()
                nparr_dest[old_num_particles:] = nparr_source

        for const in parray.constants:
            self.constants.setdefault(const, parray.constants[const])

        if num_extra_particles > 0:
            self.align_particles()
            self.is_dirty = True

        return 0

    cpdef extend(self, int num_particles):
        """ Increase the total number of particles by the requested amount

        New particles are added at the end of the list, you may have to manually
        call align_particles later.
        """
        if num_particles <= 0:
            return
        
        cdef int old_size = self.get_number_of_particles()
        cdef int new_size = old_size + num_particles
        cdef BaseArray arr
        cdef numpy.ndarray nparr

        for key in self.properties.keys():
            arr = self.properties[key]
            arr.resize(new_size)
            nparr = arr.get_npy_array()
            nparr[old_size:] = self.default_values[key]

    def get_property_index(self, prop_name):
        """ Get the index of the property in the property array """
        return self.properties.get(prop_name)

    cdef numpy.ndarray _get_real_particle_prop(self, str prop_name):
        """ get the npy array of property corresponding to only real particles

        No checks are performed. Only call this after making sure that the
        property required already exists.
        """
        cdef BaseArray prop_array
        prop_array = self.properties.get(prop_name)
        if prop_array is not None:
            return prop_array.get_npy_array()[:self.num_real_particles]
        else:
            return None

    def get_property_arrays(self, all=False):

        ret = {}
        
        if all:
            props = [i for i in self.properties.keys()]
        else:
            props = [i for i in self.properties.keys() if not i.startswith('_')]
        
        for prop in props:
            ret[prop] = self.properties[prop].get_npy_array()

        for prop in self.constants:
            ret[prop] = self.constants[prop]

        return ret

    def get(self, *args, only_real_particles=True):
        """ Return the numpy array/constant for the  property names in
        the arguments.
        
        **Parameters**

         - only_real_particles - indicates if properties of only real particles
           need to be returned or all particles to be returned. By default only
           real particles will be returned.
         - args - a list of property names.

        **Notes**

         - The returned numpy array does **NOT** own its data. Other operations
           may be performed.

        """
        cdef int nargs = len(args)
        cdef list result = []
        cdef str arg
        cdef int i
        cdef BaseArray arg_array

        if nargs == 0:
            return
        
        if only_real_particles == True:
            for i in range(nargs):
                arg = args[i]
                self._check_property(arg)
            
                if arg in self.properties:
                    arg_array = self.properties[arg]
                    result.append(
                        arg_array.get_npy_array()[:self.num_real_particles])

                else:
                    result.append(self.constants[arg])
        else:
            for i in range(nargs):
                arg = args[i]
                self._check_property(arg)
            
                if arg in self.properties:
                    arg_array = self.properties[arg]
                    result.append(arg_array.get_npy_array())
                else:
                    result.append(self.constants[arg])

        if nargs == 1:
            return result[0]
        else:
            return tuple(result)

    def set(self, **props):
        """ Set properties from numpy arrays like objects

        **Parameters**

         - props - a dictionary of properties containing the arrays to be set.

        **Notes**

         - the properties being set must already be present in the properties
           dict. 
         - the size of the data should match the array already present.

        **Issues**

         - Should the is_dirty flag be set here ? This would involve some checks
           like if the 'x', 'y' or 'z' properties were set. I do not think this
           is the correct place for setting the is_dirty flag. Let the module
           setting the coordinates handle that.

        """
        cdef str prop
        cdef BaseArray prop_array
        cdef int nprops = len(props)
        cdef list prop_names = props.keys()
        cdef int i

        for i in range(nprops):
            prop = prop_names[i]
            self._check_property(prop)
            
        for prop in props.keys():
            proparr = numpy.asarray(props[prop])
            if self.properties.has_key(prop):
                prop_array = self.properties[prop]
                prop_array.set_data(proparr)
            # if the tag property is being set, the alignment will have to be
            # changed.                 
            if prop == 'tag':
                self.align_particles()
            if prop == 'x' or prop == 'y' or prop == 'z':
                self.set_dirty(True)
    
    cpdef BaseArray get_carray(self, str prop):
        """ Return the c-array for the property """
        if PyDict_Contains(self.properties, prop) == 1:
            return <BaseArray>PyDict_GetItem(self.properties, prop)
        else:
            return None
        
    cpdef add_property(self, dict prop_info):
        """ Add a new property based on information in prop_info

        **Params**
        
            - prop_info - a dict with the following keys:

                - 'name' - compulsory key
                - 'type' - specifying the data type of this property.
                - 'default' - specifying the default value of this property.
                - 'data' - specifying the data associated with each particle.
           
                type, default and data are optional keys. They will take the
                following default values:
                type - 'double' by default
                default - 0 by default
                data - if not present, an array with all values set to default will
                be used for this property.

        **Notes**
            
            If there are no particles currently in the particle array, and a
            new property with some particles is added, all the remaining
            properties will be resized to the size of the newly added array.

            If there are some particles in the particle array, and a new
            property is added without any particles, then this new property will
            be resized according to the current size.

            If there are some particles in the particle array and a new property
            is added with a different number of particles, then an error will be
            raised.

        **Issue**

            - it is best not to add properties with data when you already have
              particles in the particle array. Reason is that, the particles in
              the particle array will be stored so that the 'Real' particles are
              in the top of the list and later the dummy ones. The data in your
              property array should be matched to the particles appropriately.
              This may not always be possible when there are particles of
              different type in the particle array. 
            - Properties without any values can be added anytime.
            - While initializing particle arrays only using the add_property
              function, you will have to call align_particles manually to make
              sure particles are aligned properly.

        """
        cdef str prop_name=None, data_type=None
        cdef object data=None, default=None
        cdef bint array_size_proper = False
        cdef PyObject* temp_obj

        temp_obj = PyDict_GetItemString(prop_info, 'name')
        if temp_obj != NULL:
            prop_name = <str>temp_obj
        temp_obj = PyDict_GetItemString(prop_info, 'type')
        if temp_obj != NULL:
            data_type = <str>temp_obj
        temp_obj = PyDict_GetItemString(prop_info, 'data')
        if temp_obj != NULL:
            data = <object>temp_obj
        temp_obj = PyDict_GetItemString(prop_info, 'default')
        if temp_obj != NULL:
            default = <object>temp_obj

        if prop_name is None:
            logger.error('Cannot add property with no name')
            raise ValueError
        
        # make sure the size of the supplied array is consistent.
        if (data is None or self.get_number_of_particles() == 0 or   
            len(data) == 0):
            array_size_proper = True
        else:
            if self.get_number_of_particles() == len(data):
                array_size_proper = True

        if array_size_proper == False:
            logger.error('Array sizes incompatible')
            raise ValueError, 'Array sizes incompatible'
        
        # setup the default values
        if default is None:
            if PyDict_Contains(self.properties, prop_name) != 1:
                default = 0
            else:
                default = <object>PyDict_GetItem(self.default_values, prop_name)
                
        PyDict_SetItem(self.default_values, prop_name, default)

        # array sizes are compatible, now resize the required arrays
        # appropriately and add.
        if self.get_number_of_particles() == 0:
            if data is None or len(data) == 0:
                # if a property with that name already exists, do not do
                # anything.
                if PyDict_Contains(self.properties, prop_name) != 1:
                    # just add the property with a zero array.
                    self.properties[prop_name] = self._create_carray(
                        data_type, 0, default)
            else:
                # new property has been added with some particles, while no
                # particles are currently present. First resize the current
                # properties to this new length, and then add this new
                # property.
                for prop in self.properties.keys():
                    arr = self.properties[prop]
                    arr.resize(len(data))
                    arr.get_npy_array()[:] = self.default_values[prop]
                if prop_name == 'tag':
                    arr = numpy.asarray(data)
                    self.num_real_particles = numpy.sum(arr==Local)
                else:
                    self.num_real_particles = len(data)

                if self.properties.has_key(prop_name):
                    # just add the particles to the already existing array.
                    d_type = self.properties[prop_name].get_npy_array().dtype
                    arr = numpy.asarray(data, dtype=d_type)
                    self.properties[prop_name].set_data(arr)
                else:
                    # now add the new property array
                    # if a type was specifed create that type of array
                    if data_type is None:
                        # get an array for this data
                        arr = numpy.asarray(data, dtype=numpy.double)
                        self.properties[prop_name] = (
                            self._create_c_array_from_npy_array(arr))
                    else:
                        arr = self._create_carray(data_type, len(data), default)
                        np_arr = arr.get_npy_array()
                        np_arr[:] = numpy.asarray(data)
                        self.properties[prop_name] = arr
        else:
            if data is None or len(data) == 0:
                # new property is added without any initial data, resize it to
                # current particle count.
                if not self.properties.has_key(prop_name):
                    arr = self._create_carray(data_type,
                                              self.get_number_of_particles(),
                                              default)
                    self.properties[prop_name] = arr
            else:
                if self.properties.has_key(prop_name):
                    d_type = self.properties[prop_name].get_npy_array().dtype
                    arr = numpy.asarray(data, dtype=d_type)
                    self.properties[prop_name].set_data(arr)
                    # realign the particles if the tag variable is being set.
                else:
                    if data_type is None:
                        # just add the property array
                        arr = numpy.asarray(data, dtype=numpy.double)
                        self.properties[prop_name] = (
                            self._create_c_array_from_npy_array(arr))
                    else:
                        arr = self._create_carray(data_type, len(data), default)
                        np_arr = arr.get_npy_array()
                        arr.get_npy_array()[:] = numpy.asarray(data)
                        self.properties[prop_name] = arr


    ######################################################################
    # Non-public interface
    ######################################################################
    def _create_carray(self, str data_type, int size, default=0):
        """ Create a carray of the requested type, and of requested size

        **Parameters**

            - data_type - string representing the 'c' data type - eg. 'int' for
            integers. 
            - size - the size of the requested array
            - default - the default value to initialize the array with.

        """
        cdef BaseArray arr
        if data_type == None:
            arr = DoubleArray(size)
        elif strcmp(PyString_AsString(data_type), 'double') == 0:
            arr = DoubleArray(size)
        elif strcmp(PyString_AsString(data_type), 'long') == 0:
            arr = LongArray(size)
        elif strcmp(PyString_AsString(data_type), 'float') == 0:
            arr = FloatArray(size)
        elif strcmp(PyString_AsString(data_type), 'int') == 0:
            arr = IntArray(size)
        elif strcmp(PyString_AsString(data_type), 'unsigned int') == 0:
            arr = UIntArray(size)
        else:
            logger.error('Trying to create carray of unknown '
                   'datatype: %s' %PyString_AsString(data_type))

        if size > 0:
            arr.get_npy_array()[:] = default

        return arr
            
    cdef _check_property(self, str prop):
        """ Check if a property is present or not """
        if (PyDict_Contains(self.properties, prop) or
            PyDict_Contains(self.constants, prop)):
            return
        else:
            raise AttributeError, 'property %s not present'%(prop)
        
    cdef object _create_c_array_from_npy_array(self, numpy.ndarray np_array):
        """ Create and return  a carray array from the given numpy array

        **Notes**
         - this function is used only when a C array needs to be
           created (in the initialize function).

        """
        cdef int np = np_array.size
        cdef object a 
        if np_array.dtype is numpy.int32 or np_array.dtype is numpy.int64:
            a = LongArray(np)
            a.set_data(np_array)
        elif np_array.dtype == numpy.float32:
            a = FloatArray(np)
            a.set_data(np_array)
        elif np_array.dtype == numpy.double:
            a = DoubleArray(np)
            a.set_data(np_array)
        else:
            msg = 'unknown numpy data type passed %s'%(np_array.dtype)
            raise TypeError, msg

        return a

    cpdef int align_particles(self) except -1:
        """ Moves all 'Local' particles to the beginning of the array

        This makes retrieving numpy slices of properties of 'Local'
        particles possible. This facility will be required frequently.

        **Algorithm**::
        
            index_arr = LongArray(n)
            
            next_insert = 0
            for i from 0 to n
                p <- ith particle
                if p is Local
                    if i != next_insert
                        tmp = index_arr[next_insert]
                        index_arr[next_insert] = i
                        index_arr[i] = tmp
                        next_insert += 1
                    else
                        index_arr[i] = i
                        next_insert += 1
                else
                    index_arr[i] = i

             # we now have the new index assignment.
             # swap the required values as needed.
             for every property array:
                 for i from 0 to n:
                     if index_arr[i] != i:
                         tmp = prop[i]
                         prop[i] = prop[index_arr[i]]
                         prop[index_arr[i]] = tmp
        """
        cdef size_t i, num_particles
        cdef size_t next_insert
        cdef size_t num_arrays
        cdef int tmp
        cdef IntArray tag_arr
        cdef LongArray index_array
        cdef BaseArray arr
        cdef list arrays
        cdef long num_real_particles = 0
        cdef long num_moves = 0

        next_insert = 0
        num_particles = self.get_number_of_particles()

        tag_arr = self.get_carray('tag')

        # malloc the new index array
        index_array = LongArray(num_particles)
        
        for i in range(num_particles):
            if tag_arr.data[i] == Local:
                num_real_particles += 1
                if i != next_insert:
                    tmp = index_array.data[next_insert]
                    index_array.data[next_insert] = i
                    index_array.data[i] = tmp
                    next_insert += 1
                    num_moves += 1
                else:
                    index_array.data[i] = i
                    next_insert += 1
            else:
                index_array.data[i] = i

        self.num_real_particles = num_real_particles
        # we now have the aligned indices. Rearrage the particles particles
        # accordingly.
        arrays = self.properties.values()
        num_arrays = len(arrays)
        
        for i in range(num_arrays):
            arr = arrays[i]
            arr._align_array(index_array)

        if num_moves > 0:
            self.is_dirty = True
            self.indices_invalid = True

    cpdef ParticleArray extract_particles(self, LongArray index_array, list
                                          props=None):
        """ Create new particle array for particles with indices in index_array

        **Parameters**

            - index_array - indices of particles to be extracted.
            - props - the list of properties to extract, if None all properties
              are extracted.

         **Algorithm**

             - create a new particle array with the required properties.
             - resize the new array to the desired length (index_array.length)
             - copy the properties from the existing array to the new array.

        """
        cdef ParticleArray result_array = ParticleArray()
        cdef list prop_names
        cdef long* idx_data
        cdef BaseArray dst_prop_array, src_prop_array
        cdef str prop_type, prop        
        
        if props is None:
            prop_names = self.properties.keys()
        else:
            prop_names = props
        
        for prop in prop_names:
            prop_type = self.properties[prop].get_c_type()
            prop_default = self.default_values[prop]
            result_array.add_property({'name':prop,
                                       'type':prop_type,
                                       'default':prop_default})

        # now we have the result array setup.
        # resize it
        if index_array.length == 0:
            return result_array
        
        result_array.extend(index_array.length)

        # now copy the values.
        idx_data = index_array.get_data_ptr()

        # copy the required indices for each property.
        for prop in prop_names:
            src_prop_array = self.get_carray(prop)
            dst_prop_array = result_array.get_carray(prop)
            src_prop_array.copy_values(index_array, dst_prop_array)

        for const in self.constants:
            result_array.constants[const] = self.constants[const]
        
        result_array.align_particles()
        result_array.name = self.name
        return result_array

    cpdef set_tag(self, long tag_value, LongArray indices):
        """ Set value of tag to tag_value for the particles in indices """
        cdef LongArray tag_array = self.get_carray('tag')
        cdef int i
        
        for i in range(indices.length):
            tag_array.data[indices.data[i]] = tag_value

    cpdef copy_properties(self, ParticleArray source, long start_index=-1, long
                          end_index=-1):
        """ Copy properties from source to self

        Parameters:
        -----------

            - source - the particle array from where to copy.
            - start_index - the first particle in self which maps to the 0th
                particle in source
            - end_index - the index of first particle from start_index that
                is not copied

        """
        cdef BaseArray src_array, dst_array
        for prop_name in source.properties:
            src_array = source.get_carray(prop_name)
            dst_array = self.get_carray(prop_name)

            if src_array != None and dst_array != None:
                dst_array.copy_subset(src_array, start_index, end_index)

    cpdef copy_over_properties(self, dict props):
        """ Copy the properties from one set to another.

        Parameters:
        -----------

        props : dict
            A mapping between the properties to be copied.

        Example:
        --------

        To save the properties 'x' and 'y' to say 'x0' and 'y0':

        pa.copy_over_properties(props = {'x':'x0', 'y':'y0'}

        """
        cdef DoubleArray dst, src
        cdef str prop

        cdef long np = self.get_number_of_particles()
        cdef long a

        for prop in props:

            src = self.get_carray( prop )
            dst = self.get_carray( props[prop] )

            for a in range( np ):
                dst.data[ a ] = src.data[ a ]

    cpdef set_to_zero(self, list props):

        cdef long np = self.get_number_of_particles()
        cdef long a

        cdef DoubleArray prop_arr
        cdef str prop

        for prop in props:
            prop_arr = self.get_carray(prop)
            
            for a in range(np):
                prop_arr.data[a] = 0.0

    cpdef update_property(self, BaseArray a, BaseArray a0,
                          BaseArray acc, double dt):
        """Update an array from another array and a scalar.

        This situation arises often when we want to update an array
        from computed accelrations. The scalar in this case will be
        the the time step.

        """
        cdef size_t npart = self.get_number_of_particles()
        cdef size_t i

        for i in range(npart):
            a.data[i] = a0.data[i] + dt*acc.data[i]        

    cpdef set_pid(self, int pid):
        """ Set the processor id for all particles """
        cdef IntArray pid_arr = self.properties['pid']
        cdef long a

        for a in range(pid_arr.length):
            pid_arr.data[a] = pid

    cpdef remove_property(self, str prop_name):
        """ Removes property prop_name from the particle array """

        if self.properties.has_key(prop_name):
            self.properties.pop(prop_name)
            self.default_values.pop(prop_name)

    def update_min_max(self, props=None):
        """ Update the min,max values of all properties """
        if props:
            for prop in props:
                array = self.properties[prop]
                array.update_min_max()
        else:
            for array in self.properties.values():
                array.update_min_max()

    cpdef resize(self, long size):
        """Resize all arrays to the new size"""
        for prop, array in self.properties.iteritems():
            array.resize(size)

    ######################################################################
    # Parallel interface
    ######################################################################
    def Send(self, int recv_proc, props=None) :
        comm = MPI.COMM_WORLD
        rank = comm.Get_rank()
        nprocs = comm.Get_size()
        if rank < 10 :
            rank_str = '0' + str(rank)
        else :
            rank_str = str(rank)
        if recv_proc < 10 :
            recv_proc_str = '0' + str(recv_proc)
        else :
            recv_proc_str = str(recv_proc)
        pre_tag = str(1) + rank_str + recv_proc_str
        tag_count = 0
        if recv_proc < nprocs :
            datasize = numpy.zeros(1)
            for prop in props :
                if self.properties.has_key(prop) :
                    datasize[0] = len(self.properties[prop])
                else :
                    props.remove(prop)
            if datasize[0] != 0 and len(props) != 0 :
                prop_count = numpy.zeros(1)
                prop_count[0] = len(props)
                tag = int(pre_tag + str(tag_count))
                comm.Send(prop_count, recv_proc, tag=tag)
                tag_count+=1
                tag = int(pre_tag + str(tag_count))
                comm.Send(datasize, recv_proc, tag=tag)
                tag_count+=1
                prop_len = numpy.zeros(len(props))
                i = 0
                for prop in props :
                    prop_len[i] = len(prop)
                    i+=1
                tag = int(pre_tag + str(tag_count))
                comm.Send(prop_len, recv_proc, tag=tag)
                tag_count+=1
                for prop in props :
                    prop_char = numpy.zeros(len(prop), dtype=numpy.character)
                    prop_char[0:] = list(prop)
                    tag = int(pre_tag + str(tag_count))
                    comm.Send([prop_char, MPI.CHARACTER], recv_proc, tag=tag)
                    tag_count+=1
                for prop in props :
                    tag = int(pre_tag + str(tag_count))
                    comm.Send(self.get(prop), recv_proc, tag=tag)
                    tag_count+=1
                    
    def Receive(self, int send_proc) :
        comm = MPI.COMM_WORLD
        rank = comm.Get_rank()
        nprocs = comm.Get_size()
        if rank < 10 :
            rank_str = '0' + str(rank)
        else :
            rank_str = str(rank)
        if send_proc < 10 :
            send_proc_str = '0' + str(send_proc)
        else :
            send_proc_str = str(send_proc)
        pre_tag = str(1) + send_proc_str + rank_str
        tag_count = 0
        recv_props = {}
        props = []
        if send_proc < nprocs :
            prop_count = numpy.zeros(1)
            tag = int(pre_tag + str(tag_count))
            comm.Recv(prop_count, send_proc, tag=tag)
            tag_count+=1
            datasize = numpy.zeros(1)
            tag = int(pre_tag + str(tag_count))
            comm.Recv(datasize, send_proc, tag=tag)
            tag_count+=1
            if datasize[0] != 0 and prop_count[0] != 0 :
                prop_len = numpy.zeros(int(prop_count[0]))
                tag = int(pre_tag + str(tag_count))
                comm.Recv(prop_len, send_proc, tag=tag)
                tag_count+=1
                for i in range(int(prop_count[0])) :
                    prop_char = numpy.zeros(int(prop_len[i]), dtype=numpy.character)
                    tag = int(pre_tag + str(tag_count))
                    comm.Recv([prop_char, MPI.CHARACTER], send_proc, tag=tag)
                    tag_count+=1
                    prop = "".join(prop_char)
                    props.append(prop)
                    recv_props[prop] = numpy.zeros(int(datasize[0]))
                for prop in props :
                    tag = int(pre_tag + str(tag_count))
                    comm.Recv(recv_props[prop], send_proc, tag=tag)
                    tag_count+=1
                self.add_particles(**recv_props)

# End of ParticleArray class
##############################################################################
