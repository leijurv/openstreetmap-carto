/* Demonstration of the !unbuffered_bbox! Mapnik token added by the patched
 * Mapnik this image builds (see Dockerfile / scripts/mapnik-config).
 *
 * The PostGIS feature query expands !bbox! beyond the (meta)tile by the Map's
 * buffer-size, while !unbuffered_bbox! stays exactly at the tile boundary. The
 * two layers in project.mml stroke each box so you can compare them:
 *
 *   red   = ST_Boundary(!unbuffered_bbox!)  -> always sits on the (meta)tile
 *           edge, so half of the thick stroke shows along every tile seam.
 *   green = ST_Boundary(!bbox!)             -> sits buffer-size px outside the
 *           tile; green is drawn last (on top), so it covers the red where they
 *           overlap.
 *
 * kosmtik's buffer-size control (the Map's bufferSize = the query buffer) drives
 * the result directly. Slide it:
 *   buffer 0   -> green coincides with red (green on top) -> green outline.
 *   buffer ~2  -> green covers most of the band, red peeks at the outer edge.
 *   buffer big -> green is pushed off-tile and clipped -> pure red outline.
 * Default buffer is 256, so out of the box you see a red border and no green.
 * (If the token were missing/broken, !unbuffered_bbox! would equal !bbox! and
 * you'd see green at every buffer size.) */

#unbuffered-bbox-demo {
  line-color: #ff0000;
  line-width: 16;
  line-opacity: 1;
}

#bbox-demo {
  line-color: #00ff00;
  line-width: 16;
  line-opacity: 1;
}
