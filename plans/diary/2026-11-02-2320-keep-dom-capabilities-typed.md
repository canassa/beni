# Keep DOM capabilities typed

Dom now uses generated native operations for element lookup, focus, geometry,
scrolling and fullscreen. Fullscreen promises and their rejections retain
their types through Task.resume. Only a TypeError is a fullscreen refusal;
unknown rejections are raised unchanged. Native capability checks keep the
existing unsupported and activation behavior.

Native validation and 15 focused browser program runs passed across DOM
capabilities, fullscreen, after-render focus and focus during a flush.
Behavioral goldens stayed unchanged. HostFree remains off for other families.
