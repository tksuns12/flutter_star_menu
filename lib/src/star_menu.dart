/*
Copyright (c) 2019-2021, Marco Bavagnoli <marcobavagnolidev@gmail.com>
All rights reserved.
 */
import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:star_menu/src/dinamyc_star_menu.dart';
import 'package:vector_math/vector_math_64.dart' as vector;

import 'params/linear_shape_params.dart';
import 'params/star_menu_params.dart';
import 'star_item.dart';
import 'widget_params.dart';

enum MenuState {
  closed,
  closing,
  opening,
  open,
}

enum MenuShape {
  circle,
  linear,
  grid,
}

enum ArcType {
  semiUp,
  semiDown,
  semiLeft,
  semiRight,
  quarterTopRight,
  quarterTopLeft,
  quarterBottomRight,
  quarterBottomLeft,
}

/// Extension on Widget to add a StarMenu easily
extension AddStarMenu on Widget {
  addStarMenu({
    List<Widget>? items,
    Future<List<Widget>> Function()? lazyItems,
    Function(MenuState state)? onStateChanged,
    StarMenuParameters params = const StarMenuParameters(),
    StarMenuController? controller,
    Function(int index, StarMenuController controller)? onItemTapped,
  }) {
    return StarMenu(
      params: params,
      items: items,
      lazyItems: lazyItems,
      onStateChanged: onStateChanged,
      controller: controller,
      onItemTapped: onItemTapped,
      child: this,
    );
  }
}

/// Controller sent back with [onItemTapped] to
/// let you choose to close the menu
class StarMenuController {
  VoidCallback? openMenu;
  VoidCallback? closeMenu;

  bool isInitialized() {
    return openMenu != null && closeMenu != null;
  }

  void dispose() {
    openMenu = null;
    closeMenu = null;
  }
}

class StarMenu extends StatefulWidget {
  /// parameters of this menu
  final StarMenuParameters params;

  /// widget items entry list
  final List<Widget>? items;

  /// function to build dynamically items list whenever the menu open occurs
  final Future<List<Widget>> Function()? lazyItems;

  /// widget that triggers the opening of the menu
  /// Only [child] or [parentContext] is allowed
  final Widget? child;

  /// context of the Widget where the menu will be opened
  /// Only [child] or [parentContext] is allowed
  final BuildContext? parentContext;

  /// controls to open/close the menu programmatically
  final StarMenuController? controller;

  /// return current menu state
  final Function(MenuState state)? onStateChanged;

  /// The callback that is called when a menu item is tapped.
  /// It gives the `ID` of the item and a `controller` to
  /// eventually close the menu
  final Function(int index, StarMenuController controller)? onItemTapped;

  StarMenu({
    Key? key,
    controller,
    this.params = const StarMenuParameters(),
    this.items,
    this.lazyItems,
    this.onStateChanged,
    this.onItemTapped,
    this.child,
    this.parentContext,
  })  : assert(
          !(items == null && lazyItems == null),
          'StarMenu: You have to set items or lazyItems!',
        ),
        assert(
          !(items != null && lazyItems != null),
          'StarMenu: You can only pass items or lazyItems, not both.',
        ),
        assert(!(child == null && parentContext == null),
            'StarMenu: You have to set child or parentContext!'),
        assert(!(child != null && parentContext != null),
            'StarMenu: You can set child or parentContext, not both!'),
        controller = controller ?? StarMenuController(),
        super(key: key);

  @override
  StarMenuState createState() => StarMenuState();
}

class StarMenuState extends State<StarMenu>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  AnimationController? _controller;
  late Animation<double> _animationPercent;
  List<Widget> _items = [];
  Rect itemsBounds = Rect.zero;

  late double lineAngleRAD;
  late double circleStartAngleRAD;
  late double circleEndAngleRAD;
  late double rotateItemsAnimationAngleRAD;
  OverlayEntry? overlayEntry;
  late Rect parentBounds;
  late MenuState menuState;
  Size? screenSize;
  late double topPadding;
  late List<WidgetParams> itemsParams;
  late List<GlobalKey> itemKeys;
  late List<Matrix4> itemsMatrix; // final position matrix of animation
  late ValueNotifier<double> animationProgress;
  late bool paramsAlreadyGot;
  late Offset offsetToFitMenuIntoScreen;
  Offset touchLocalPoint = Offset.zero;

  Timer? longPressTimer;

  @override
  void initState() {
    super.initState();
    _init();
  }

  _init() {
    if (widget.items != null) _items = widget.items!;

    menuState = MenuState.closed;
    overlayEntry = null;
    lineAngleRAD = vector.radians(widget.params.linearShapeParams.angle);
    circleStartAngleRAD =
        vector.radians(widget.params.circleShapeParams.startAngle);
    circleEndAngleRAD =
        vector.radians(widget.params.circleShapeParams.endAngle);
    rotateItemsAnimationAngleRAD =
        vector.radians(widget.params.rotateItemsAnimationAngle);

    animationProgress = ValueNotifier<double>(0.0);
    offsetToFitMenuIntoScreen = Offset.zero;
    paramsAlreadyGot = false;
    itemsParams = List.generate(_items.length,
        (index) => WidgetParams(xPosition: 0, yPosition: 0, rect: Rect.zero));
    itemsMatrix = List.generate(_items.length, (index) => Matrix4.identity());

    _setupAnimationController();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _dispose();
    super.dispose();
  }

  _dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _animationPercent.removeListener(_animationListener);
    overlayEntry?.remove();
    overlayEntry = null;
    menuState = MenuState.closed;
    if (!(_controller?.isDismissed ?? false)) {
      _controller?.stop();
      _controller?.value = 0;
      _controller?.dispose();
    }
  }

  @override
  void reassemble() {
    super.reassemble();
    resetForChanges();
  }

  @override
  void didChangeMetrics() {
    if (menuState == MenuState.closed) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      resetForChanges();
    });
  }

  resetForChanges() {
    if (_items.isEmpty || menuState == MenuState.closed) return;

    MenuState state = menuState;

    _dispose();
    _init();

    menuState = MenuState.closed;
    if (state == MenuState.open) {
      closeMenu();
      showMenu();
    }
  }

  _animationListener() {
    animationProgress.value = _animationPercent.value;

    /// Time to get items parameters?
    if (_animationPercent.value > 0 && !paramsAlreadyGot) {
      itemsParams = List.generate(
          _items.length,
          (index) => WidgetParams.fromContext(
              itemKeys.elementAt(index).currentContext));

      itemsMatrix = _calcPosition();
      _checkBoundaries();
      paramsAlreadyGot = true;

      // maybe lazyItems are not yet in the tree. Maybe there is a better way
      if (widget.lazyItems != null) {
        for (int i = 0; i < itemsParams.length; i++) {
          if (itemsParams.elementAt(i).rect.isEmpty) {
            paramsAlreadyGot = false;
            return;
          }
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Point startPoint = Point(0, 0);

    if (!widget.controller!.isInitialized()) {
      widget.controller!.openMenu = showMenu;
      widget.controller!.closeMenu = closeMenu;
    }

    if (StarMenuOverlay.isMounted(this)) {
      WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
        showMenu();
      });
    }

    return Listener(
      onPointerDown: (event) {
        startPoint = Point(event.position.dx, event.position.dy);
        touchLocalPoint =
            Offset(event.localPosition.dx, event.localPosition.dy);
        if (widget.params.useLongPress) {
          longPressTimer = Timer(widget.params.longPressDuration, () {
            if (startPoint
                    .distanceTo(Point(event.position.dx, event.position.dy)) <
                10) showMenu();
          });
        }
      },
      onPointerUp: (event) {
        if (widget.params.useLongPress) {
          longPressTimer?.cancel();
          return;
        }
        if (startPoint.distanceTo(Point(event.position.dx, event.position.dy)) <
            10) showMenu();
      },
      child: widget.child ?? SizedBox.shrink(),
    );
  }

  // setup animation controller
  _setupAnimationController() {
    _controller = AnimationController(
      duration: Duration(milliseconds: widget.params.openDurationMs),
      vsync: this,
    );

    _animationPercent = Tween(begin: 0.0, end: 1.0).animate(CurvedAnimation(
        parent: _controller!, curve: widget.params.animationCurve))
      ..addListener(_animationListener)
      ..addStatusListener((AnimationStatus status) {
        switch (status) {
          case AnimationStatus.completed:
            if (_controller?.value == 1.0) {
              menuState = MenuState.open;
            } else
              menuState = MenuState.closed;
            break;
          case AnimationStatus.dismissed:
            if (_animationPercent.value == 0) {
              overlayEntry?.remove();
              overlayEntry = null;
              _controller?.value = 0;
              menuState = MenuState.closed;
            }
            break;
          case AnimationStatus.reverse:
            menuState = MenuState.closing;
            break;
          case AnimationStatus.forward:
            menuState = MenuState.opening;
            break;
        }

        if (widget.onStateChanged != null) widget.onStateChanged!(menuState);
      });
  }

  /// Close the menu
  closeMenu() {
    _controller
        ?.animateBack(
      0,
      duration: Duration(milliseconds: widget.params.closeDurationMs),
    )
        .then((value) {
      if (widget.parentContext != null) {
        _dispose();
        StarMenuOverlay.dispose();
      }
    });
  }

  /// Open the menu
  showMenu() {
    // padding, viewInsets and viewPadding return 0 here! Force to be 24
    // topPadding = MediaQuery.of(context).viewPadding.top;
    topPadding = 24; // system toolBar height
    screenSize = Size(
        MediaQuery.of(context).size.width, MediaQuery.of(context).size.height);

    if (widget.lazyItems != null) {
      widget.lazyItems!().then((value) {
        _items = value;
        paramsAlreadyGot = false;
        _showMenu();
      });
    } else {
      paramsAlreadyGot = false;
      _showMenu();
    }
  }

  _showMenu() {
    overlayEntry = _overlayEntryBuilder();
    _controller?.reset();

    if (overlayEntry != null) {
      // find parent widget bounds
      RenderBox? renderBox = widget.child != null
          ? (context.findRenderObject() as RenderBox)
          : (widget.parentContext!.findRenderObject() as RenderBox);
      Rect widgetRect = renderBox.paintBounds;
      Offset parentPosition = renderBox.localToGlobal(Offset.zero);
      parentBounds = widgetRect.translate(parentPosition.dx, parentPosition.dy);

      OverlayState? overlay = Overlay.of(context);
      overlay?.insert(overlayEntry!);
      overlayEntry?.addListener(() {
        if (overlayEntry != null &&
            overlayEntry!.mounted &&
            menuState == MenuState.closed) _controller?.forward();
      });
    }
  }

  /// Create the overlay object
  OverlayEntry _overlayEntryBuilder() {
    // keys used to get items rect
    itemKeys = List.generate(_items.length, (index) => GlobalKey());

    return OverlayEntry(
      // maintainState: true,
      builder: (context) {
        return Directionality(
          textDirection: TextDirection.ltr,
          child: ValueListenableBuilder(
              valueListenable: animationProgress,
              builder: (_, double animValue, __) {
                Color background =
                    widget.params.backgroundParams.backgroundColor;
                if (widget.params.backgroundParams.animatedBackgroundColor)
                  background =
                      Color.lerp(Colors.transparent, background, animValue) ??
                          background;

                Widget child = Material(
                  color: background,
                  child: Stack(
                      children: [
                    GestureDetector(
                      onTap: () {
                        // this optional check is to just not call
                        // closeMenu() if an item without an onTap
                        // event is tapped. Else the tap is on
                        // background and the menu must be closed
                        if (!(menuState == MenuState.closing ||
                            menuState == MenuState.closed)) closeMenu();
                      },
                    ),

                    // draw background container
                    if (widget.params.boundaryBackground != null)
                      Transform.translate(
                        offset: Offset(
                          itemsBounds.left -
                              widget.params.boundaryBackground!.padding.left,
                          itemsBounds.top -
                              widget.params.boundaryBackground!.padding.top,
                        ),
                        child: ClipRRect(
                          child: BackdropFilter(
                            filter: ImageFilter.blur(
                                sigmaX: widget.params.boundaryBackground
                                        ?.blurSigmaX ??
                                    0.0,
                                sigmaY: widget.params.boundaryBackground
                                        ?.blurSigmaY ??
                                    0.0),
                            child: Container(
                              width: itemsBounds.width +
                                  widget
                                      .params.boundaryBackground!.padding.left +
                                  widget
                                      .params.boundaryBackground!.padding.right,
                              height: itemsBounds.height +
                                  widget
                                      .params.boundaryBackground!.padding.top +
                                  widget.params.boundaryBackground!.padding
                                      .bottom,
                              decoration:
                                  widget.params.boundaryBackground!.decoration,
                            ),
                          ),
                        ),
                      ),

                      // draw background container
                      if (widget.params.boundaryBackground != null)
                        Transform.translate(
                          offset: Offset(
                            itemsBounds.left -
                                widget.params.boundaryBackground!.padding.left,
                            itemsBounds.top -
                                widget.params.boundaryBackground!.padding.top,
                          ),
                          child: Container(
                            width: itemsBounds.width +
                                widget.params.boundaryBackground!.padding.left +
                                widget.params.boundaryBackground!.padding.right,
                            height: itemsBounds.height +
                                widget.params.boundaryBackground!.padding.top +
                                widget
                                    .params.boundaryBackground!.padding.bottom,
                            decoration:
                                widget.params.boundaryBackground!.decoration,
                          ),
                        ),
                    ]..addAll(List.generate(_items.length, (index) {
                            if (index >= itemKeys.length) return Container();
                            if (index >= itemsMatrix.length) return Container();
                            if (index >= _items.length) return Container();
                            return StarItem(
                              key: itemKeys.elementAt(index),
                              child: _items[index],
                              totItems: _items.length,
                              index: index,
                              // center: parentBounds.center,
                              // animation start from previous item position
                              center: Offset(
                                  itemsMatrix
                                      .elementAt(index - 1 >= 0 ? index - 1 : 0)
                                      .getTranslation()
                                      .x,
                                  itemsMatrix
                                      .elementAt(index - 1 >= 0 ? index - 1 : 0)
                                      .getTranslation()
                                      .y),
                              itemMatrix: itemsMatrix[index],
                              rotateRAD: rotateItemsAnimationAngleRAD,
                              scale: widget.params.startItemScaleAnimation,
                              onHoverScale: widget.params.onHoverScale,
                              shift: Offset(
                                  itemsMatrix
                                          .elementAt(index)
                                          .getTranslation()
                                          .x +
                                      offsetToFitMenuIntoScreen.dx,
                                  itemsMatrix
                                          .elementAt(index)
                                          .getTranslation()
                                          .y +
                                      offsetToFitMenuIntoScreen.dy),
                              animValue: animValue,
                              onItemTapped: (id) {
                                if (widget.onItemTapped != null)
                                  widget.onItemTapped!(id, widget.controller!);
                              },
                            );
                          }))),
                  ),
                );

                // is background blurred?
                if ((widget.params.backgroundParams.sigmaX > 0 ||
                        widget.params.backgroundParams.sigmaY > 0) &&
                    animValue > 0) {
                  late double db;
                  if (widget.params.backgroundParams.animatedBlur)
                    db = animValue;
                  else
                    db = 1.0;
                  child = BackdropFilter(
                    filter: ImageFilter.blur(
                        sigmaX: widget.params.backgroundParams.sigmaX * db,
                        sigmaY: widget.params.backgroundParams.sigmaY * db),
                    child: child,
                  );
                }

                return child;
              }),
        );
      },
    );
  }

  // Calculate final item center position
  List<Matrix4> _calcPosition() {
    List<Matrix4> ret =
        List.generate(_items.length, (index) => Matrix4.identity());
    Offset newCenter = widget.params.useScreenCenter
        ? Offset(screenSize!.width / 2 + widget.params.centerOffset.dx,
            screenSize!.height / 2 + widget.params.centerOffset.dy)
        : parentBounds.center + widget.params.centerOffset;
    if (widget.params.useTouchAsCenter && touchLocalPoint != Offset.zero) {
      newCenter = Offset(
        parentBounds.left + touchLocalPoint.dx,
        parentBounds.top + touchLocalPoint.dy,
      );
    }
    offsetToFitMenuIntoScreen = Offset.zero;

    switch (widget.params.shape) {
      case MenuShape.circle:
        // if the circle isn't complete, the last item should
        // be positioned at the ending angle. Otherwise on the ending
        // angle there is already the 1st item
        int nItems = (widget.params.circleShapeParams.endAngle -
                    widget.params.circleShapeParams.startAngle <
                360)
            ? _items.length - 1
            : _items.length;

        ret.asMap().forEach((index, mat) {
          mat.translate(
              newCenter.dx +
                  cos((circleEndAngleRAD - circleStartAngleRAD) /
                              nItems *
                              index +
                          circleStartAngleRAD) *
                      widget.params.circleShapeParams.radiusX,
              newCenter.dy -
                  sin((circleEndAngleRAD - circleStartAngleRAD) /
                              nItems *
                              index +
                          circleStartAngleRAD) *
                      widget.params.circleShapeParams.radiusY);
        });
        break;

      case MenuShape.linear:
        double radius = 0.0;
        double rotate = lineAngleRAD;
        double itemDiameter = 0.0;
        double firstItemHalfWidth = 0.0;
        double firstItemHalfHeight = 0.0;
        late double halfWidth;
        late double halfHeight;
        double secH;
        double secV;

        ret.asMap().forEach((index, mat) {
          halfWidth = itemsParams[index].rect.width / 2;
          halfHeight = itemsParams[index].rect.height / 2;

          // itemDiameter is calculated by the segment length that intersect
          // the item bounding box passing through the center of the item
          // and intersect the opposite edges by m_startingAngle angle
          secH = (halfHeight / sin(rotate)).abs();
          secV = (halfWidth / sin(pi / 2 - rotate)).abs();

          // checks if the line intersect horizontal or vertical edges
          if (secH < secV)
            itemDiameter = secH * 2.0;
          else
            itemDiameter = secV * 2.0;

          // These checks if the line is perfectly vertical or horizontal
          if ((rotate + pi / 2) / pi == ((rotate + pi / 2) / pi).ceil())
            itemDiameter = halfHeight * 2;
          if (rotate / pi == (rotate / pi).ceil()) itemDiameter = halfWidth * 2;

          if (index == 0) {
            firstItemHalfWidth = halfWidth;
            firstItemHalfHeight = halfHeight;
            mat.translate(newCenter.dx, newCenter.dy);
          } else {
            double alignmentShiftX = 0;
            double alignmentShiftY = 0;
            if (widget.params.linearShapeParams.alignment ==
                LinearAlignment.left) {
              alignmentShiftX = halfWidth - firstItemHalfWidth;
            }
            if (widget.params.linearShapeParams.alignment ==
                LinearAlignment.right) {
              alignmentShiftX = -halfWidth + firstItemHalfWidth;
            }
            if (widget.params.linearShapeParams.alignment ==
                LinearAlignment.top) {
              alignmentShiftY = halfHeight - firstItemHalfHeight;
            }
            if (widget.params.linearShapeParams.alignment ==
                LinearAlignment.bottom) {
              alignmentShiftY = -halfHeight + firstItemHalfHeight;
            }
            mat.translate(
                cos(lineAngleRAD) * (radius + halfWidth - firstItemHalfWidth) +
                    newCenter.dx +
                    alignmentShiftX,
                -sin(lineAngleRAD) *
                        (radius + halfHeight - firstItemHalfHeight) +
                    newCenter.dy +
                    alignmentShiftY);
          }

          radius += itemDiameter + widget.params.linearShapeParams.space;
        });

        break;

      case MenuShape.grid:
        int j = 0;
        int k = 0;
        int n = 0;
        double x = 0;
        double y = 0;
        int count = 0;
        double hMax = 0;
        double wMax = 0;
        double itemWidth;
        double itemHeight;
        List<double> rowsWidth = [];
        List<Point> itemPos = [];

        // Calculating the grid
        while (j * widget.params.gridShapeParams.columns + k < _items.length) {
          count = 0;
          hMax = 0;
          x = 0;
          // Calculate x position and rows height
          while (k < widget.params.gridShapeParams.columns &&
              j * widget.params.gridShapeParams.columns + k < _items.length) {
            itemWidth =
                itemsParams[widget.params.gridShapeParams.columns * j + k]
                    .rect
                    .width;
            itemHeight =
                itemsParams[widget.params.gridShapeParams.columns * j + k]
                    .rect
                    .height;
            itemPos.add(Point(x + itemWidth / 2, y));
            // hMax = max item height in this row
            hMax = max(hMax, itemHeight);
            x += itemWidth + widget.params.gridShapeParams.columnsSpaceH;
            count++;
            k++;
          }
          // wMax = max width of all rows
          wMax = max(wMax, x);
          rowsWidth.add(x - widget.params.gridShapeParams.columnsSpaceH);
          // Calculate y position for items in current row
          for (int i = 0; i < count; i++) {
            itemHeight = itemsParams[
                    widget.params.gridShapeParams.columns * j + k - i - 1]
                .rect
                .height;
            double x1 = itemPos[itemPos.length - i - 1].x.toDouble();
            double y1 = y + hMax / 2;
            itemPos[itemPos.length - i - 1] = Point(x1, y1);
          }
          y += hMax + widget.params.gridShapeParams.columnsSpaceV;
          k = 0;
          j++;
        }

        y -= widget.params.gridShapeParams.columnsSpaceV;
        // At this point:
        //    y = grid height
        //    wMax = grid width
        //    rowsWidth = list containing all the rows width
        //    it is now possible to center rows and
        //    center the grid in parent item
        n = 0;
        int dx;
        while (n < _items.length) {
          dx = ((wMax -
                      rowsWidth[(n / widget.params.gridShapeParams.columns)
                          .floor()]) /
                  2)
              .floor();
          ret[n] = Matrix4.identity()
            ..translate((itemPos[n].x + dx - wMax / 2) + newCenter.dx,
                (itemPos[n].y - y / 2) + newCenter.dy);
          n++;
        }
        break;
    }

    return ret;
  }

  // check if the items rect exceeds the screen. Move the item positions
  // to fit into the screen
  _checkBoundaries() {
    if (widget.params.checkItemsScreenBoundaries && itemsParams.isNotEmpty) {
      for (int i = 0; i < itemsParams.length; i++) {
        Rect shifted = itemsParams[i].rect.translate(
            itemsMatrix.elementAt(i).getTranslation().x -
                itemsParams[i].rect.width / 2,
            itemsMatrix.elementAt(i).getTranslation().y -
                itemsParams[i].rect.height / 2);

        if (shifted.left < 0) itemsMatrix.elementAt(i).translate(-shifted.left);
        if (shifted.right > screenSize!.width)
          itemsMatrix.elementAt(i).translate(screenSize!.width - shifted.right);
        if (shifted.top < topPadding)
          itemsMatrix.elementAt(i).translate(0.0, topPadding - shifted.top);
        if (shifted.bottom > screenSize!.height)
          itemsMatrix
              .elementAt(i)
              .translate(0.0, screenSize!.height - shifted.bottom);
      }
    }

    // check if the rect that include all the items on final position
    // exceeds the screen. Move all items position accordingly
    if (widget.params.checkMenuScreenBoundaries && itemsParams.isNotEmpty) {
      Rect boundaries = itemsParams[0].rect.translate(
          itemsMatrix.elementAt(0).getTranslation().x -
              itemsParams[0].rect.width / 2,
          itemsMatrix.elementAt(0).getTranslation().y -
              itemsParams[0].rect.height / 2);
      for (int i = 1; i < itemsParams.length; i++) {
        boundaries = boundaries.expandToInclude(itemsParams[i].rect.translate(
            itemsMatrix.elementAt(i).getTranslation().x -
                itemsParams[i].rect.width / 2,
            itemsMatrix.elementAt(i).getTranslation().y -
                itemsParams[i].rect.height / 2));
      }

      // if there is a [boundaryBackground], add its padding to the [boundaries]
      if (widget.params.boundaryBackground != null) {
        boundaries = Rect.fromLTRB(
          boundaries.left + widget.params.boundaryBackground!.padding.left,
          boundaries.top + widget.params.boundaryBackground!.padding.top,
          boundaries.right + widget.params.boundaryBackground!.padding.right,
          boundaries.bottom + widget.params.boundaryBackground!.padding.bottom,
        );
      }

      if (boundaries.top < topPadding)
        offsetToFitMenuIntoScreen = offsetToFitMenuIntoScreen.translate(
            0, -boundaries.top + topPadding);
      if (boundaries.bottom > screenSize!.height)
        offsetToFitMenuIntoScreen = offsetToFitMenuIntoScreen.translate(
            0, screenSize!.height - boundaries.bottom);
      if (boundaries.left < 0)
        offsetToFitMenuIntoScreen =
            offsetToFitMenuIntoScreen.translate(-boundaries.left, 0);
      if (boundaries.right > screenSize!.width)
        offsetToFitMenuIntoScreen = offsetToFitMenuIntoScreen.translate(
            screenSize!.width - boundaries.right, 0);
    }

    // calculate the whole items boundary
    if (itemsMatrix.isNotEmpty) {
      itemsBounds = Rect.fromLTWH(
          itemsMatrix.elementAt(0).getTranslation().x -
              itemsParams[0].rect.width / 2 +
              offsetToFitMenuIntoScreen.dx,
          itemsMatrix.elementAt(0).getTranslation().y -
              itemsParams[0].rect.height / 2 +
              offsetToFitMenuIntoScreen.dy,
          itemsParams[0].rect.width,
          itemsParams[0].rect.height);
    }
    for (int i = 1; i < itemsParams.length; i++) {
      itemsBounds = itemsBounds.expandToInclude(Rect.fromLTWH(
          itemsMatrix.elementAt(i).getTranslation().x -
              itemsParams[i].rect.width / 2 +
              offsetToFitMenuIntoScreen.dx,
          itemsMatrix.elementAt(i).getTranslation().y -
              itemsParams[i].rect.height / 2 +
              offsetToFitMenuIntoScreen.dy,
          itemsParams[i].rect.width,
          itemsParams[i].rect.height));
    }
  }
}
