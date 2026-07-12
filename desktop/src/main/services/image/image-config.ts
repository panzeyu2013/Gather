export const IMAGE_CONFIG = {
  sharp: {
    supportedExtensions: [
      '.jpg', '.jpeg', '.png', '.tif', '.tiff', '.webp',
      '.nef', '.nrw', '.cr2', '.dng', '.orf', '.pef', '.srw',
      '.arw', '.rw2', '.raf', '.mef', '.mos', '.3fr',
      '.erf', '.kdc', '.mrw', '.x3f',
    ],
    rawExtensions: [
      '.nef', '.nrw', '.cr2', '.dng', '.orf', '.pef', '.srw',
      '.arw', '.rw2', '.raf', '.mef', '.mos', '.3fr',
      '.erf', '.kdc', '.mrw', '.x3f',
    ],
  },

  sips: {
    rawExtensions: [
      '.cr2', '.cr3', '.nef', '.nrw', '.arw',
      '.raf', '.dng', '.orf', '.rw2', '.pef',
      '.srw', '.srf', '.x3f', '.3fr', '.fff',
      '.mef', '.mos', '.iiq', '.eip', '.erf',
      '.kdc', '.mrw',
    ],
  },
}
