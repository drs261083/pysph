"""Example of a very simple rigid body motion to test the rigid body equations.
"""

import numpy as np

from pysph.base.kernels import CubicSpline
from pysph.base.utils import get_particle_array_rigid_body
from pysph.sph.equation import Group

from pysph.sph.integrator import EPECIntegrator

from pysph.solver.application import Application
from pysph.solver.solver import Solver
from pysph.sph.rigid_body import (BodyForce, RigidBodyCollision,
    RigidBodyMoments, RigidBodyMotion, RK2StepRigidBody)

dim = 3

dt = 5e-3
tf = 5.0
gz = -9.81

hdx = 1.0
dx = dy = 0.02
rho0 = 10.0



def create_particles(**kw):

    nx, ny, nz = 10, 10, 10
    dx = 1.0/(nx-1)
    x, y, z = np.mgrid[0:1:nx*1j, 0:1:ny*1j, 0:1:nz*1j]
    x = x.flat
    y = y.flat
    z = (z - 1).flat
    m = np.ones_like(x)*dx*dx*rho0
    h = np.ones_like(x)*hdx*dx
    body = get_particle_array_rigid_body(
        name='body', x=x, y=y, z=z, h=h, m=m,
    )

    body.vc[0] = -5.0
    body.vc[2] = -5.0

    # Create the tank.
    nx, ny, nz = 40, 40, 40
    dx = 1.0/(nx-1)
    xmin, xmax, ymin, ymax, zmin, zmax = -2, 2, -2, 2, -2, 2
    x, y, z = np.mgrid[xmin:xmax:nx*1j, ymin:ymax:ny*1j, zmin:zmax:nz*1j]
    interior = ((x < 1.8) & (x > -1.8)) & ((y < 1.8) & (y> -1.8)) & ((z > -1.8) & (z <= 2))
    tank = np.logical_not(interior)
    x = x[tank].flat
    y = y[tank].flat
    z = z[tank].flat
    m = np.ones_like(x)*dx*dx*rho0
    h = np.ones_like(x)*hdx*dx
    tank = get_particle_array_rigid_body(
        name='tank', x=x, y=y, z=z, h=h, m=m,
    )
    tank.total_mass[0] = np.sum(m)


    return [body, tank]

# Create the application.
app = Application()

# Create the kernel
kernel = CubicSpline(dim=dim)

# Create the Integrator. Currently, PySPH supports multi-stage,
# predictor corrector and a TVD-RK3 integrators.

integrator = EPECIntegrator(body=RK2StepRigidBody())

# Create a solver.
solver = Solver(kernel=kernel, dim=dim, integrator=integrator,
                dt=dt, tf=tf, adaptive_timestep=False)
solver.set_print_freq(10)

# create the equations
equations = [
    Group(equations=[
        BodyForce(dest='body', sources=None, gz=gz),
        RigidBodyCollision(
            dest='body', sources=['tank'], k=1.0, d=2.0, eta=0.25, kt=0.25
        )]
    ),
    Group(equations=[RigidBodyMoments(dest='body', sources=None)]),
    Group(equations=[RigidBodyMotion(dest='body', sources=None)]),
]

# Setup the application and solver.  This also generates the particles.
app.setup(solver=solver, equations=equations,
          particle_factory=create_particles)

app.run()
