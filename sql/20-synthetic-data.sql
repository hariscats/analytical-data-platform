\set ON_ERROR_STOP on

-- Deterministic synthetic hyperspectral cubes. Shrink with: psql -v grid=8 -v bands=16
\if :{?grid}
\else
    \set grid 32
\endif
\if :{?bands}
\else
    \set bands 64
\endif

-- Surface reflectance (0-1) for a material at a wavelength. Seeding only; dropped below.
CREATE FUNCTION imagery.synthetic_reflectance(
    material text,
    wavelength_nm double precision,
    noise_seed integer
)
RETURNS double precision
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT least(1, greatest(0,
        CASE material
            -- Green peak, red edge near 715 nm, falling SWIR plateau.
            WHEN 'vegetation' THEN
                0.04
                + 0.06 * exp(-least(50, ((wavelength_nm - 550) / 40) ^ 2))
                + 0.41 / (1 + exp(-(wavelength_nm - 715) / 18))
                    * (1 - 0.45 / (1 + exp(-(wavelength_nm - 1300) / 150)))
            -- Dark, falling to near zero in the near infrared.
            WHEN 'water' THEN
                0.005 + 0.06 * exp(-(wavelength_nm - 400) / 150)
            -- Bright and spectrally flat.
            WHEN 'built' THEN
                0.22 + 0.04 * (wavelength_nm - 400) / 2100
            -- Soil: rising slope with a clay feature near 2200 nm.
            ELSE
                0.08 + 0.27 * (wavelength_nm - 400) / 2100
                - 0.05 * exp(-least(50, ((wavelength_nm - 2200) / 40) ^ 2))
        END
        -- Atmospheric water-vapour absorption.
        * (1
            - 0.85 * exp(-least(50, ((wavelength_nm - 1400) / 45) ^ 2))
            - 0.90 * exp(-least(50, ((wavelength_nm - 1900) / 55) ^ 2)))
        + 0.004 * sin(noise_seed * 12.9898 + wavelength_nm * 0.0783)
    ))
$$;

INSERT INTO imagery.scene (
    scene_id, mission_id, sensor, acquired_at, center_lat, center_lon,
    cloud_cover_pct, gsd_m, width_px, height_px, band_count,
    release_status, raw_uri, processing_note
)
SELECT
    format('%s-%s', m.mission_id, lpad(n::text, 4, '0')),
    m.mission_id,
    'SYN-HSI-' || m.mission_id,
    timestamptz '2026-09-01 10:30:00+00' + make_interval(days => (n - 1) * 7 + m.ordinal),
    m.base_lat + n * 0.0123,
    m.base_lon - n * 0.0171,
    (n * 9 + m.ordinal * 4) % 35,
    30.0,
    :grid,
    :grid,
    :bands,
    CASE WHEN n = 4 THEN 'embargoed' ELSE 'released' END,
    format('raw://%s/%s-%s.h5', lower(m.mission_id), m.mission_id, lpad(n::text, 4, '0')),
    'Synthetic scene for API demonstrations; not real imagery.'
FROM (
    VALUES
        ('A', 0, 35.10000, -116.20000),
        ('B', 1, -23.60000, 133.90000)
) AS m (mission_id, ordinal, base_lat, base_lon)
CROSS JOIN generate_series(1, 4) AS n;

INSERT INTO imagery.spectrum (
    scene_id, mission_id, pixel_row, pixel_col, band_id,
    wavelength_nm, reflectance, quality_flag
)
SELECT
    s.scene_id,
    s.mission_id,
    p.pixel_row,
    p.pixel_col,
    b.band_id,
    b.wavelength_nm,
    -- Cloud cover adds a uniform bright haze.
    round((
        imagery.synthetic_reflectance(
            p.material, b.wavelength_nm::double precision,
            s.seed * 100000 + p.pixel_row * 1000 + p.pixel_col
        ) * (1 - s.haze) + 0.55 * s.haze
    )::numeric, 4)::real,
    CASE
        WHEN abs(b.wavelength_nm - 1400) <= 75 OR abs(b.wavelength_nm - 1900) <= 75 THEN 1
        ELSE 0
    END
FROM (
    SELECT
        scene.*,
        ascii(mission_id) + right(scene_id, 4)::integer AS seed,
        cloud_cover_pct / 100 * 0.5 AS haze
    FROM imagery.scene
) AS s
CROSS JOIN LATERAL (
    SELECT
        r AS pixel_row,
        c AS pixel_col,
        CASE
            -- A diagonal river that shifts between scenes.
            WHEN abs(r - (c + s.seed * 3) % s.width_px) < greatest(1, s.width_px / 12) THEN 'water'
            -- A built-up block in the lower left.
            WHEN r BETWEEN s.height_px * 0.65 AND s.height_px * 0.80
                AND c BETWEEN s.width_px * 0.10 AND s.width_px * 0.30 THEN 'built'
            WHEN sin(r * 0.45 + s.seed) + cos(c * 0.35 - s.seed) > 0.4 THEN 'vegetation'
            ELSE 'soil'
        END AS material
    FROM generate_series(0, s.height_px - 1) AS r
    CROSS JOIN generate_series(0, s.width_px - 1) AS c
) AS p
CROSS JOIN LATERAL (
    SELECT
        band_id::smallint AS band_id,
        round(400 + (band_id - 1) * 2100.0 / (s.band_count - 1), 2) AS wavelength_nm
    FROM generate_series(1, s.band_count) AS band_id
) AS b;

DROP FUNCTION imagery.synthetic_reflectance(text, double precision, integer);

ANALYZE imagery.scene, imagery.spectrum;

SELECT
    (SELECT count(*) FROM imagery.scene) AS scenes,
    (SELECT count(*) FROM imagery.spectrum) AS spectral_samples;
