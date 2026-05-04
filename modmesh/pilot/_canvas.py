# Copyright (c) 2026, Han-Xuan Huang <c1ydehhx@gmail.com>
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# - Redistributions of source code must retain the above copyright notice, this
#   list of conditions and the following disclaimer.
# - Redistributions in binary form must reproduce the above copyright notice,
#   this list of conditions and the following disclaimer in the documentation
#   and/or other materials provided with the distribution.
# - Neither the name of the copyright holder nor the names of its contributors
#   may be used to endorse or promote products derived from this software
#   without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

"""
Canvas utilities and curve/conic drawing utilities for pilot GUI.
"""

import numpy as np

from PySide6 import QtWidgets

from .. import core, plot

from . import _gui_common

__all__ = [
    'Canvas',
    'ShapeCreateDialog',
    'CurveSampler',
    'Ellipse',
    'Parabola',
    'Hyperbola',
    'BezierSample',
    'BezierSampler',
]


class Canvas(_gui_common.PilotFeature):
    """
    Canvas feature providing menu items for drawing curves and polygons.
    """

    def __init__(self, *args, **kw):
        super(Canvas, self).__init__(*args, **kw)
        self._world = core.WorldFp64()
        self._widget = None

    def populate_menu(self):
        self._add_menu_item(
            menu=self._mgr.canvasMenu,
            text="Clear Canvas",
            tip="Remove all shapes and clear the canvas",
            func=self._clear_canvas,
        )

        self._mgr.canvasMenu.addSeparator()

        self._add_menu_item(
            menu=self._mgr.canvasMenu,
            text="Add Line...",
            tip="Create a line segment by specifying two endpoints",
            func=self._add_line_dialog,
        )
        self._add_menu_item(
            menu=self._mgr.canvasMenu,
            text="Add Rectangle...",
            tip="Create a rectangle by specifying min/max corners",
            func=self._add_rectangle_dialog,
        )
        self._add_menu_item(
            menu=self._mgr.canvasMenu,
            text="Add Square...",
            tip="Create a square by specifying lower-left corner and side "
                "length",
            func=self._add_square_dialog,
        )
        self._add_menu_item(
            menu=self._mgr.canvasMenu,
            text="Add Ellipse...",
            tip="Create an ellipse by specifying center and radii",
            func=self._add_ellipse_dialog,
        )
        self._add_menu_item(
            menu=self._mgr.canvasMenu,
            text="Add Circle...",
            tip="Create a circle by specifying center and radius",
            func=self._add_circle_dialog,
        )
        self._add_menu_item(
            menu=self._mgr.canvasMenu,
            text="Add Triangle...",
            tip="Create a triangle by specifying three vertices",
            func=self._add_triangle_dialog,
        )

        self._mgr.canvasMenu.addSeparator()

        self._add_menu_item(
            menu=self._mgr.canvasMenu,
            text="Sample: Create ICCAD-2013",
            tip="Create ICCAD-2013 polygon examples",
            func=self.mesh_iccad_2013,
        )

        tip = "Draw a sample S-shaped cubic Bezier curve with control points"
        self._add_menu_item(
            menu=self._mgr.canvasMenu,
            text="Sample: Bezier S-curve",
            tip=tip,
            func=self._bezier_s_curve,
        )
        self._add_menu_item(
            menu=self._mgr.canvasMenu,
            text="Sample: Bezier Arch",
            tip="Draw a sample arch-shaped cubic Bezier curve with control "
                "points",
            func=self._bezier_arch,
        )
        self._add_menu_item(
            menu=self._mgr.canvasMenu,
            text="Sample: Bezier Loop",
            tip="Draw a sample loop-like cubic Bezier curve with control "
                "points",
            func=self._bezier_loop,
        )
        self._add_menu_item(
            menu=self._mgr.canvasMenu,
            text="Sample: Ellipse",
            tip="Draw a sample ellipse (a=2, b=1)",
            func=self._ellipse,
        )
        self._add_menu_item(
            menu=self._mgr.canvasMenu,
            text="Sample: Parabola",
            tip="Draw a sample parabola (y = 0.5*x^2)",
            func=self._parabola,
        )
        self._add_menu_item(
            menu=self._mgr.canvasMenu,
            text="Sample: Hyperbola",
            tip="Draw a sample hyperbola (both branches)",
            func=self._hyperbola,
        )
        self._add_menu_item(
            menu=self._mgr.canvasMenu,
            text="Sample: Line",
            tip="Draw a sample line segment from (0, 0) to (3, 2)",
            func=self._sample_line,
        )
        self._add_menu_item(
            menu=self._mgr.canvasMenu,
            text="Sample: Rectangle",
            tip="Draw a sample rectangle with corners (0,0) and (4,2)",
            func=self._sample_rectangle,
        )
        self._add_menu_item(
            menu=self._mgr.canvasMenu,
            text="Sample: Square",
            tip="Draw a sample square at (0,0) with side length 3",
            func=self._sample_square,
        )
        self._add_menu_item(
            menu=self._mgr.canvasMenu,
            text="Sample: Circle",
            tip="Draw a sample circle centered at (2,2) with radius 1.5",
            func=self._sample_circle,
        )
        self._add_menu_item(
            menu=self._mgr.canvasMenu,
            text="Sample: Triangle",
            tip="Draw a sample triangle with vertices at "
                "(0,0), (3,0), (1.5,2)",
            func=self._sample_triangle,
        )

    @staticmethod
    def _draw_layer(world, layer):
        point_type = core.Point3dFp64

        for polygon in layer.get_polys():
            segment_pad = core.SegmentPadFp64(ndim=2)

            for coord in polygon:
                segment_pad.append(core.Segment3dFp64(
                    point_type(coord[0][0], coord[0][1]),
                    point_type(coord[1][0], coord[1][1])
                ))

            world.add_segments(pad=segment_pad)

    def mesh_iccad_2013(self):
        layer = plot.plane_layer.PlaneLayer()
        layer.add_figure("RECT N M1 70 800 180 40")
        layer.add_figure(
            "PGON N M1 70 720 410 720 410 920 70 920 "
            "70 880 370 880 370 760 70 760"
        )
        layer.add_figure("RECT N M1 70 1060 180 40")
        layer.add_figure(
            "PGON N M1 70 980 410 980 410 1180 70 1180 "
            "70 1140 370 1140 370 1020 70 1020"
        )

        self._draw_layer(self._world, layer)
        self._update_widget()

    def _update_widget(self):
        if self._widget is None:
            self._widget = self._mgr.add3DWidget()
        self._widget.updateWorld(self._world)
        self._widget.showMark()

    def _bezier_s_curve(self):
        bezier_sample = BezierSample.s_curve()
        sampler = BezierSampler(self._world, bezier_sample)
        sampler.draw(nsample=50, fac=1.0, off_x=0.0, off_y=0.0)
        self._update_widget()

    def _bezier_arch(self):
        bezier_sample = BezierSample.arch()
        sampler = BezierSampler(self._world, bezier_sample)
        sampler.draw(nsample=50, fac=1.0, off_x=0.0, off_y=0.0)
        self._update_widget()

    def _bezier_loop(self):
        bezier_sample = BezierSample.loop()
        sampler = BezierSampler(self._world, bezier_sample)
        sampler.draw(nsample=50, fac=1.0, off_x=0.0, off_y=0.0)
        self._update_widget()

    def _ellipse(self):
        ellipse = Ellipse(a=2.0, b=1.0)
        sampler = CurveSampler(self._world, ellipse)
        sampler.populate_points(npoint=100)
        sampler.draw_cbc()
        self._update_widget()

    def _parabola(self):
        parabola = Parabola(a=0.5, t_min=-3.0, t_max=6.0)
        sampler = CurveSampler(self._world, parabola)
        sampler.populate_points(npoint=100)
        sampler.draw_cbc()
        self._update_widget()

    def _hyperbola(self):
        hyperbola = Hyperbola(a=1.0, b=1.0, t_min=-2.0, t_max=2.0)

        right_sampler = CurveSampler(self._world, hyperbola)
        right_sampler.populate_points(npoint=100)
        right_sampler.draw_cbc()

        left_sampler = CurveSampler(self._world, hyperbola)
        left_sampler.populate_points(npoint=100)
        left_sampler.points.x.ndarray[:] *= -1.0
        left_sampler.draw_cbc()

        self._update_widget()

    def _clear_canvas(self):
        self._world = core.WorldFp64()
        self._update_widget()

    # --- interactive creation dialogs ---

    def _add_line_dialog(self):
        dlg = ShapeCreateDialog(
            title="Add Line",
            fields=[("x0", 0.0), ("y0", 0.0), ("x1", 3.0), ("y1", 2.0)],
            parent=self._mainWindow,
        )
        if dlg.exec():
            v = dlg.values()
            self._world.add_line(v["x0"], v["y0"], v["x1"], v["y1"])
            self._update_widget()

    def _add_rectangle_dialog(self):
        dlg = ShapeCreateDialog(
            title="Add Rectangle",
            fields=[
                ("x_min", 0.0), ("y_min", 0.0),
                ("x_max", 4.0), ("y_max", 2.0),
            ],
            parent=self._mainWindow,
        )
        if dlg.exec():
            v = dlg.values()
            self._world.add_rectangle(
                v["x_min"], v["y_min"], v["x_max"], v["y_max"])
            self._update_widget()

    def _add_square_dialog(self):
        dlg = ShapeCreateDialog(
            title="Add Square",
            fields=[("x_min", 0.0), ("y_min", 0.0), ("size", 3.0)],
            parent=self._mainWindow,
        )
        if dlg.exec():
            v = dlg.values()
            self._world.add_square(v["x_min"], v["y_min"], v["size"])
            self._update_widget()

    def _add_ellipse_dialog(self):
        dlg = ShapeCreateDialog(
            title="Add Ellipse",
            fields=[
                ("cx", 0.0), ("cy", 0.0),
                ("rx", 2.0), ("ry", 1.0),
            ],
            parent=self._mainWindow,
        )
        if dlg.exec():
            v = dlg.values()
            self._world.add_ellipse(v["cx"], v["cy"], v["rx"], v["ry"])
            self._update_widget()

    def _add_circle_dialog(self):
        dlg = ShapeCreateDialog(
            title="Add Circle",
            fields=[("cx", 0.0), ("cy", 0.0), ("r", 1.5)],
            parent=self._mainWindow,
        )
        if dlg.exec():
            v = dlg.values()
            self._world.add_circle(v["cx"], v["cy"], v["r"])
            self._update_widget()

    def _add_triangle_dialog(self):
        dlg = ShapeCreateDialog(
            title="Add Triangle",
            fields=[
                ("x0", 0.0), ("y0", 0.0),
                ("x1", 3.0), ("y1", 0.0),
                ("x2", 1.5), ("y2", 2.0),
            ],
            parent=self._mainWindow,
        )
        if dlg.exec():
            v = dlg.values()
            self._world.add_triangle(
                v["x0"], v["y0"],
                v["x1"], v["y1"],
                v["x2"], v["y2"],
            )
            self._update_widget()

    # --- sample presets for new shape APIs ---

    def _sample_line(self):
        self._world.add_line(0.0, 0.0, 3.0, 2.0)
        self._update_widget()

    def _sample_rectangle(self):
        self._world.add_rectangle(0.0, 0.0, 4.0, 2.0)
        self._update_widget()

    def _sample_square(self):
        self._world.add_square(0.0, 0.0, 3.0)
        self._update_widget()

    def _sample_circle(self):
        self._world.add_circle(2.0, 2.0, 1.5)
        self._update_widget()

    def _sample_triangle(self):
        self._world.add_triangle(0.0, 0.0, 3.0, 0.0, 1.5, 2.0)
        self._update_widget()


class ShapeCreateDialog(QtWidgets.QDialog):
    """
    Generic dialog for creating a 2D shape by specifying numeric parameters.

    Each field is a (name, default_value) pair rendered as a QDoubleSpinBox.
    Call values() after exec() returns True to get a dict of field values.
    """

    def __init__(self, title, fields, parent=None):
        super().__init__(parent)
        self.setWindowTitle(title)
        self._spinboxes = {}
        self._build_ui(fields)

    def _build_ui(self, fields):
        form = QtWidgets.QFormLayout()
        for name, default in fields:
            spin = QtWidgets.QDoubleSpinBox()
            spin.setRange(-1e9, 1e9)
            spin.setDecimals(4)
            spin.setSingleStep(0.1)
            spin.setValue(default)
            self._spinboxes[name] = spin
            form.addRow(name, spin)

        buttons = QtWidgets.QDialogButtonBox(
            QtWidgets.QDialogButtonBox.Ok |
            QtWidgets.QDialogButtonBox.Cancel
        )
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)

        layout = QtWidgets.QVBoxLayout()
        layout.addLayout(form)
        layout.addWidget(buttons)
        self.setLayout(layout)

    def values(self):
        return {name: spin.value()
                for name, spin in self._spinboxes.items()}


class CurveSampler:
    """
    Sample analytic curves into points and draw them as cubic Bezier chains.
    """

    def __init__(self, world, curve):
        self.world = world
        self.curve = curve
        self.points = None

    def populate_points(self, npoint=100, fac=1.0, off_x=0.0, off_y=0.0):
        """
        Populate sampled curve points and apply an affine transform.

        npoint controls sampling density.
        fac is a uniform scale factor.
        off_x and off_y are translation offsets in x and y.
        """
        if npoint < 1:
            raise ValueError("npoint must be at least 1")

        self.points = self.curve.calc_points(npoint)
        self.points.x.ndarray[:] = self.points.x.ndarray * fac + off_x
        self.points.y.ndarray[:] = self.points.y.ndarray * fac + off_y

    def draw_cbc(self, spacing=0.01):
        """
        Draw sampled points as a cubic Bezier chain.

        spacing is the target chord-length step used to choose per-segment
        Bezier sampling density. Smaller spacing produces denser rendering.
        """
        if self.points is None:
            raise RuntimeError(
                "populate_points() must be called before draw_cbc()"
            )
        if spacing <= 0:
            raise ValueError("spacing must be positive")
        if len(self.points) < 2:
            return

        point_type = core.Point3dFp64
        point_x = self.points.x.ndarray
        point_y = self.points.y.ndarray
        segment_length = np.hypot(
            point_x[:-1] - point_x[1:],
            point_y[:-1] - point_y[1:],
        )
        # Minimum of 2 so very short segments are still visible.
        nsample = np.maximum((segment_length // spacing).astype(int) - 1, 2)

        for index in range(len(self.points) - 1):
            p0 = np.array(self.points[index])
            p3 = np.array(self.points[index + 1])
            delta = p3 - p0
            # Place interior cubic control points at 1/3 and 2/3 so each
            # cubic segment represents a straight line between p0 and p3.
            p1 = p0 + (1.0 / 3.0) * delta
            p2 = p0 + (2.0 / 3.0) * delta
            bezier = self.world.add_bezier(
                p0=point_type(p0[0], p0[1], 0.0),
                p1=point_type(p1[0], p1[1], 0.0),
                p2=point_type(p2[0], p2[1], 0.0),
                p3=point_type(p3[0], p3[1], 0.0),
            )
            bezier.sample(int(nsample[index]))


class Ellipse:
    def __init__(self, a=2.0, b=1.0):
        self.a = a
        self.b = b

    def calc_points(self, npoint):
        t_array = np.linspace(0.0, 2.0 * np.pi, npoint + 1, dtype='float64')
        point_pad = core.PointPadFp64(ndim=2, nelem=npoint + 1)
        for index, t_value in enumerate(t_array):
            x_value = self.a * np.cos(t_value)
            y_value = self.b * np.sin(t_value)
            point_pad.set_at(index, x_value, y_value)
        return point_pad


class Parabola:
    def __init__(self, a=0.5, t_min=-3.0, t_max=3.0):
        self.a = a
        self.t_min = t_min
        self.t_max = t_max

    def calc_points(self, npoint):
        t_array = np.linspace(self.t_min, self.t_max, npoint + 1,
                              dtype='float64')
        point_pad = core.PointPadFp64(ndim=2, nelem=npoint + 1)
        for index, t_value in enumerate(t_array):
            x_value = t_value
            y_value = self.a * t_value * t_value
            point_pad.set_at(index, x_value, y_value)
        return point_pad


class Hyperbola:
    def __init__(self, a=1.0, b=1.0, t_min=-2.0, t_max=2.0):
        self.a = a
        self.b = b
        self.t_min = t_min
        self.t_max = t_max

    def calc_points(self, npoint):
        t_array = np.linspace(self.t_min, self.t_max, npoint + 1,
                              dtype='float64')
        point_pad = core.PointPadFp64(ndim=2, nelem=npoint + 1)
        for index, t_value in enumerate(t_array):
            x_value = self.a * np.cosh(t_value)
            y_value = self.b * np.sinh(t_value)
            point_pad.set_at(index, x_value, y_value)
        return point_pad


class BezierSample(object):
    def __init__(self, p0, p1, p2, p3):
        self.p0 = p0
        self.p1 = p1
        self.p2 = p2
        self.p3 = p3

    @classmethod
    def s_curve(cls):
        return cls(p0=(0.0, 0.0), p1=(1.0, 3.0),
                   p2=(4.0, -1.0), p3=(5.0, 2.0))

    @classmethod
    def arch(cls):
        return cls(p0=(0.0, 0.0), p1=(1.5, 4.0),
                   p2=(3.5, 4.0), p3=(5.0, 0.0))

    @classmethod
    def loop(cls):
        return cls(p0=(0.0, 0.0), p1=(5.0, 3.0),
                   p2=(0.0, 3.0), p3=(5.0, 0.0))


class BezierSampler(object):
    def __init__(self, world, bezier_sample):
        self.world = world
        self.bezier_sample = bezier_sample

    def draw(self, nsample=50, fac=1.0, off_x=0.0, off_y=0.0,
             show_control_polygon=True, show_control_points=True):
        point_type = core.Point3dFp64
        bezier_sample = self.bezier_sample

        def _point(xy_pair):
            return point_type(xy_pair[0] * fac + off_x,
                              xy_pair[1] * fac + off_y, 0)

        p0 = _point(bezier_sample.p0)
        p1 = _point(bezier_sample.p1)
        p2 = _point(bezier_sample.p2)
        p3 = _point(bezier_sample.p3)

        bezier = self.world.add_bezier(p0=p0, p1=p1, p2=p2, p3=p3)
        bezier.sample(nsample)

        if show_control_polygon:
            self.world.add_segment(p0, p1)
            self.world.add_segment(p1, p2)
            self.world.add_segment(p2, p3)

        if show_control_points:
            mark_size = 0.1 * fac
            for point in (p0, p1, p2, p3):
                self.world.add_segment(
                    point_type(point.x - mark_size, point.y, 0),
                    point_type(point.x + mark_size, point.y, 0)
                )
                self.world.add_segment(
                    point_type(point.x, point.y - mark_size, 0),
                    point_type(point.x, point.y + mark_size, 0)
                )


# vim: set ff=unix fenc=utf8 et sw=4 ts=4 sts=4 tw=79:
