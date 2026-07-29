export interface GalleryAspectItem {
  width: number
  height: number
}

export interface JustifiedLayoutItem {
  index: number
  width: number
}

export interface JustifiedLayoutRow {
  height: number
  items: JustifiedLayoutItem[]
  justified: boolean
}

interface PendingItem {
  index: number
  aspectRatio: number
}

function safeAspectRatio(item: GalleryAspectItem): number {
  if (item.width <= 0 || item.height <= 0) return 1
  const ratio = item.width / item.height
  return Number.isFinite(ratio) && ratio > 0 ? ratio : 1
}

function rowHeight(
  items: PendingItem[],
  containerWidth: number,
  gap: number,
): number {
  const availableWidth = containerWidth - gap * Math.max(0, items.length - 1)
  const aspectRatioSum = items.reduce((sum, item) => sum + item.aspectRatio, 0)
  return availableWidth / aspectRatioSum
}

function makeRow(
  items: PendingItem[],
  height: number,
  justified: boolean,
): JustifiedLayoutRow {
  return {
    height,
    justified,
    items: items.map((item) => ({
      index: item.index,
      width: item.aspectRatio * height,
    })),
  }
}

/**
 * Produces Flickr/Google Photos-style rows: every photo in a row has the same
 * height while its natural aspect ratio determines its width. Completed rows
 * fill the container; the final row remains left-aligned at the target height.
 */
export function layoutJustifiedRows(
  source: GalleryAspectItem[],
  containerWidth: number,
  targetRowHeight: number,
  gap = 8,
): JustifiedLayoutRow[] {
  if (source.length === 0 || containerWidth <= 0 || targetRowHeight <= 0) {
    return []
  }

  const rows: JustifiedLayoutRow[] = []
  let pending: PendingItem[] = []

  const finalize = (items: PendingItem[]) => {
    if (items.length === 0) return
    rows.push(makeRow(items, rowHeight(items, containerWidth, gap), true))
  }

  source.forEach((item, index) => {
    pending.push({ index, aspectRatio: safeAspectRatio(item) })

    const projectedWidth = pending.reduce(
      (sum, pendingItem) => sum + pendingItem.aspectRatio * targetRowHeight,
      gap * Math.max(0, pending.length - 1),
    )
    if (projectedWidth < containerWidth) return

    if (pending.length === 1) {
      finalize(pending)
      pending = []
      return
    }

    const withoutLast = pending.slice(0, -1)
    const heightWithLast = rowHeight(pending, containerWidth, gap)
    const heightWithoutLast = rowHeight(withoutLast, containerWidth, gap)

    if (
      Math.abs(heightWithoutLast - targetRowHeight)
      < Math.abs(heightWithLast - targetRowHeight)
    ) {
      finalize(withoutLast)
      pending = [pending[pending.length - 1]]
    } else {
      finalize(pending)
      pending = []
    }
  })

  if (pending.length > 0) {
    const naturalHeight = rowHeight(pending, containerWidth, gap)
    const finalHeight = Math.min(targetRowHeight, naturalHeight)
    rows.push(makeRow(pending, finalHeight, false))
  }

  return rows
}
