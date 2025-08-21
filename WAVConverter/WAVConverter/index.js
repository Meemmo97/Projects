const { tmpdir } = require('os');
const { join } = require('path');
const { writeFileSync, readFileSync, unlinkSync, existsSync, chmodSync } = require('fs');
const { spawnSync } = require('child_process');
let ffmpeg;
try {
  ffmpeg = require('ffmpeg-static');
} catch {
  ffmpeg = null;
}

module.exports = async function (context, req) {
  // ...existing code...
  try {
    const { name = 'audio.wav', contentBytes } = req.body || {};
    if (!contentBytes) {
      context.res = { status: 400, body: { error: "Missing 'contentBytes' base64" } };
      return;
    }

  const inPath  = join(tmpdir(), 'in.tmp');
  const outPath = join(tmpdir(), 'out.wav');

  // Rimuovo eventuale prefisso data URL e decodifico base64
  const base64Clean = contentBytes.replace(/^data:.*;base64,/, '');
  const buf = Buffer.from(base64Clean, 'base64');
  writeFileSync(inPath, buf);

  // Log diagnostico: dimensione e primi byte
  context.log('File size:', buf.length);
  context.log('First bytes:', buf.slice(0, 16));

  // Check if file is likely a WAV (starts with 'RIFF')
  const wavSignature = buf.slice(0, 4).toString('ascii');
  context.log('WAV signature:', wavSignature);
  if (wavSignature !== 'RIFF') {
    context.res = {
      status: 400,
      body: { error: "Input file is not a valid WAV (missing 'RIFF' signature)", firstBytes: buf.slice(0, 16).toString('hex') }
    };
    return;
  }

      // Fallback: use system ffmpeg, or bin/ffmpeg if not found
      let ffmpegBin = ffmpeg;
      if (!ffmpegBin || (typeof ffmpegBin === 'string' && !existsSync(ffmpegBin))) {
        // Try custom static binary path in bin/
        const customFfmpegPath = join(__dirname, 'bin', 'ffmpeg');
        if (existsSync(customFfmpegPath)) {
          ffmpegBin = customFfmpegPath;
          try { chmodSync(ffmpegBin, 0o755); } catch (e) { context.log('chmod ffmpeg failed:', e.message); }
          context.log('Using custom static ffmpeg binary:', ffmpegBin);
        } else {
          ffmpegBin = 'ffmpeg';
          context.log('Falling back to system ffmpeg');
        }
      } else {
        try { chmodSync(ffmpegBin, 0o755); } catch (e) { context.log('chmod ffmpeg failed:', e.message); }
      }

    // ffmpeg: WAV PCM 16-bit, mono, 16kHz
    const args = ['-y', '-i', inPath, '-acodec', 'pcm_s16le', '-ac', '1', '-ar', '16000', outPath];
    const result = spawnSync(ffmpegBin, args, {
      encoding: 'utf8',
      env: { ...process.env, FFMPEG_PATH: ffmpegBin },
      stdio: ['ignore', 'pipe', 'pipe']
    });

    if (result.error || result.status !== 0) {
      const details = (result && (result.stderr || result.error?.message)) || null;
      context.log('ffmpeg failed', { status: result.status, error: result.error?.message, stderr: result.stderr });
      context.res = { status: 500, body: { error: 'ffmpeg failed', details } };
      return;
    }

  const outB64 = readFileSync(outPath).toString('base64');
    // cleanup best-effort
    try { unlinkSync(inPath); } catch {}
    try { unlinkSync(outPath); } catch {}

    context.res = {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
      body: { name: 'audio.wav', contentBytes: outB64 }
    };
  } catch (e) {
    context.res = { status: 500, body: { error: e.message } };
  }
};
