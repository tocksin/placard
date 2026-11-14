# skyward_nes_instruments.py - Skyward Tobi 4's music/instruments.py, copied unchanged below
# this header (github.com/Zebshine/skyward-tobi-4, v0.9.8) for
# skyward_music.py, which arranges the songs for the Placard's music player.
#
# Copyright (c) 2026 Mark Szlemko.  MIT License (the notice is in
# gen_skyward.py).
#
# Date: 11/14/2026
# Instrument definitions. env = per-frame volume (0-15), last value held
# unless 'eloop' given. arp = per-frame semitone offsets (noise: period-index
# offsets). slide = signed period delta per frame (+ = pitch down).
# vib = depth 1-4, vdel = frames before vibrato starts. duty 0-3.
def decay(start, step_frames, floor=0):
    out, v = [], start
    while v > floor:
        out += [v] * step_frames
        v -= 1
    return out + [floor]

INSTRUMENTS = {
    # ---- music: pulse.  Voicing calibrated against register logs of late-80s Nintendo NES
    # scores (Oct 17 study, music/study/): leads peak at volume 10 on a 25% duty and DECAY on
    # every note (short notes die within 8 frames, long notes slide 10 -> 3 and never hold flat),
    # vibrato is essentially absent, harmony sits at 7 and stabs at 7 fade in four frames.
    'lead':   dict(duty=1, env=[10, 9, 8, 7, 6, 6, 5, 5, 4, 4, 3, 3, 3, 2, 2, 2]),
    'lead1':  dict(duty=1, env=[11, 9, 8, 7, 6, 5, 5, 4, 4, 3, 3, 2, 2, 2]),            # punchier attack (boss, star); 25 % like the rest
    'leadv':  dict(duty=1, env=[9, 10, 9, 8, 7, 7, 6, 6, 5, 5, 4, 4, 4, 3, 3, 3], vib=1, vdel=20),  # soaring lines: a late, shallow vibrato
    'stac':   dict(duty=1, env=[10, 9, 7, 6, 5, 4, 3, 2, 0]),                           # the 8-frame pluck
    'stac1':  dict(duty=0, env=[9, 8, 6, 5, 4, 3, 2, 1, 0]),
    'harm':   dict(duty=1, env=[7, 6, 6, 5, 5, 4, 4, 3, 3, 2, 2, 2]),
    'harm2':  dict(duty=0, env=[6, 6, 5, 5, 4, 4, 3, 3, 2, 2]),
    'chord':  dict(duty=1, env=[7, 6, 6, 5, 3, 1, 0]),
    'arpM':   dict(duty=1, env=[7, 7, 6, 6, 5, 5, 4, 3, 2, 1, 0], arp=[0, 0, 4, 4, 7, 7], aloop=0),
    'arpm':   dict(duty=1, env=[7, 7, 6, 6, 5, 5, 4, 3, 2, 1, 0], arp=[0, 0, 3, 3, 7, 7], aloop=0),
    'arpMs':  dict(duty=1, env=[7, 7, 6, 6, 5, 5, 4, 4, 3, 3, 2, 2, 1, 1, 0], arp=[0, 4, 7], aloop=0),
    'arpms':  dict(duty=1, env=[7, 7, 6, 6, 5, 5, 4, 4, 3, 3, 2, 2, 1, 1, 0], arp=[0, 3, 7], aloop=0),
    'arpds':  dict(duty=1, env=[7, 7, 6, 6, 5, 5, 4, 4, 3, 3, 2, 2, 1, 1, 0], arp=[0, 3, 6], aloop=0),
    'bell':   dict(duty=0, env=[11, 10, 8, 7, 6, 5, 4, 4, 3, 3, 2, 2, 1, 1, 0]),
    'pad':    dict(duty=2, env=[1, 2, 2, 2, 2, 2, 2]),   # MMC5 harmony pad (no vib: cheap); Oct 17 night D42: peak 3 -> 2
    'fan':    dict(duty=2, env=[10, 10, 9, 8, 8, 7, 7, 6, 6, 5, 5, 5, 4, 4, 4, 4, 3, 3, 3, 3]),  # fanfare brass: full, but it decays
    'fan1':   dict(duty=1, env=[7, 7, 6, 6, 5, 5, 5, 4, 4, 4, 3, 3, 3, 3]),
    'pslap':  dict(duty=1, env=[5, 4, 3, 3, 2, 2, 1, 1, 0]),   # Oct 18 night: MMC5 P4 doubles the bass an octave up as a short pluck
    'echo':   dict(duty=1, env=[3, 3, 2, 2, 2, 1, 1, 0]),   # MMC5 echo of the lead: fades out; Oct 17 night D42: peak 4 -> 3
    # ---- music: triangle (any nonzero env value = sounding)
    'tri':    dict(env=[1]),
    'tris':   dict(env=[1, 1, 1, 1, 1, 1, 0]),          # staccato bass
    'trim':   dict(env=[1] * 14 + [0]),                  # medium pluck (march "oom")
    'trik':   dict(env=[1, 1, 1, 0], arp=[12, 7, 0, 0]),  # triangle 'kick' blip
    # Oct 18 night: bass that drives through (Castlevania III's triangle sounds 96% of the time,
    # ours did 51-59%): held until one frame before the next 8th at each song's tempo
    'trid9':  dict(env=[1] * 9 + [0]),                   # 10-frame 8ths (overworld)
    'trid14': dict(env=[1] * 14 + [0]),                  # desert camel walk
    'trid16': dict(env=[1] * 16 + [0]),                  # fortress march
    'trid24': dict(env=[1] * 24 + [0]),                  # sky waltz (27-frame quarters)
    # ---- music: noise drums (arp = period index offsets)
    'nkick':  dict(env=[9, 6, 3, 1, 0], arp=[0, 1, 2, 3]),          # click on top of the DPCM kick
    'nsnare': dict(env=[12, 11, 9, 8, 6, 5, 4, 3, 2, 1, 0], arp=[0, 0, 1]),
    'nhat':   dict(env=[6, 4, 2, 0]),                  # short tick (noise period 3, as measured on the reference cart)
    'nqhat':  dict(env=[4, 2, 0]),
    'nohat':  dict(env=[6, 6, 5, 4, 4, 3, 2, 2, 1, 0]),
    'ncrash': dict(env=decay(11, 2)),
    'ntom':   dict(env=[8, 6, 4, 3, 2, 1, 0], arp=[0, 0, 1, 1, 2]),   # air on top of the DPCM tom
    'nbig':   dict(env=[14, 13, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0], arp=[0, 0, 1, 1, 2]),
    # ---- sound effects: pulse
    'sjump':  dict(duty=2, env=[11, 11, 10, 10, 9, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0], slide=-14),
    'sbjump': dict(duty=1, env=[12, 12, 11, 11, 10, 10, 9, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0], slide=-11),
    'scoin':  dict(duty=1, env=[12, 11, 10, 9, 9, 8, 8, 7, 7, 6, 6, 5, 5, 4, 4, 3, 3, 2, 2, 1, 1, 0]),
    'sdrop':  dict(duty=2, env=[13, 12, 10, 8, 6, 4, 2, 0], slide=30),
    'sbump':  dict(duty=2, env=[12, 10, 8, 6, 4, 2, 0], slide=12),
    'srise':  dict(duty=2, env=[8, 9, 9, 9, 8, 8, 8, 7, 7, 7, 6, 6, 6, 5, 5, 5, 4, 4, 3, 3, 2, 2, 1, 0], slide=-5, vib=3, vdel=0),
    'sfan':   dict(duty=2, env=[13, 13, 12, 11, 10, 10, 9, 9, 8, 8, 7, 7, 6, 5, 4, 3, 2, 1, 0]),
    'sfan1':  dict(duty=1, env=[9, 9, 8, 8, 7, 7, 6, 6, 5, 5, 4, 4, 3, 2, 1, 0]),
    'shurt':  dict(duty=2, env=[12, 12, 11, 11, 10, 10, 9, 9, 8, 8, 7, 7, 6, 6, 5, 5, 4, 4, 3, 3, 2, 1, 0], slide=7, vib=4, vdel=0),
    'sbell':  dict(duty=0, env=[14, 12, 10, 9, 8, 7, 6, 5, 5, 4, 4, 3, 3, 2, 2, 1, 1, 0]),
    'sclick': dict(duty=0, env=[13, 9, 5, 2, 0]),
    'spew':   dict(duty=1, env=[11, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0], slide=22),
    'sboing': dict(duty=2, env=[12, 12, 11, 11, 10, 10, 9, 9, 8, 8, 7, 7, 6, 6, 5, 5, 4, 3, 2, 1, 0], slide=-9, vib=4, vdel=0),
    'sclang': dict(duty=0, env=[15, 13, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0], arp=[0, 6, 0, 6, 1, 7], aloop=0),
    'sblip':  dict(duty=1, env=[10, 9, 7, 5, 3, 1, 0]),
    'swarn':  dict(duty=2, env=[12, 12, 11, 10, 9, 8, 0]),
    'swhoo':  dict(duty=1, env=[3, 5, 7, 8, 8, 7, 6, 5, 4, 3, 2, 1, 0], slide=-18),
    # ---- sound effects: noise
    'zthud':  dict(env=[13, 11, 8, 5, 3, 1, 0], arp=[0, 1, 2, 3]),
    'zcrunch': dict(env=[14, 13, 12, 10, 9, 8, 7, 6, 5, 4, 4, 3, 3, 2, 2, 1, 1, 0], arp=[0, 0, 1, 2, 1, 2, 3, 3, 4]),
    'ztick':  dict(env=[9, 5, 2, 0]),
    'zhiss':  dict(env=[4, 6, 7, 7, 6, 5, 4, 3, 2, 1, 0]),
    'zflap':  dict(env=[3, 6, 8, 6, 4, 2, 1, 0], arp=[2, 1, 0, 0, 1, 2]),
    'zswoop': dict(env=[2, 3, 4, 5, 6, 7, 7, 7, 6, 6, 5, 5, 4, 3, 2, 1, 0],
                   arp=[6, 6, 5, 5, 4, 4, 3, 3, 2, 2, 1, 1, 0, 0, 0, 1, 2]),
    'zcrash': dict(env=decay(13, 2)),
}

# music noise-channel drum letters -> (instrument, noise value: $10 bit = loop mode)
DRUMS = {
    'K': ('nkick', 0x0C),
    'S': ('nsnare', 0x07),
    'H': ('nhat', 0x03),
    'Q': ('nqhat', 0x00),
    'O': ('nohat', 0x02),
    'X': ('ncrash', 0x04),
    'T': ('ntom', 0x0A),
    'B': ('nbig', 0x06),
}
# Oct 18 night: the sampled kit (music/dpcm.py). Letter -> (sample, DMC rate index). The noise
# instrument still plays on top (a click on the kick, the crack of the snare); the toms are the
# kick sample played faster, the big drum the kick played slower.
DRUM_DMC = {
    'K': ('kick', 14),
    'S': ('snare', 15),
    'T': ('kick', 15),
    'B': ('kick', 12),
}
