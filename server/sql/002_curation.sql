-- What the athlete edited by hand on a service (Strava for now): name, commute flag, bike, precise
-- sport type. Filled by the highest-priority copy like the other metrics.

ALTER TABLE activity ADD COLUMN IF NOT EXISTS name        text;
ALTER TABLE activity ADD COLUMN IF NOT EXISTS description text;
ALTER TABLE activity ADD COLUMN IF NOT EXISTS sport_type  text;     -- e.g. Ride, EBikeRide, Walk (Strava's names)
ALTER TABLE activity ADD COLUMN IF NOT EXISTS commute     boolean;
ALTER TABLE activity ADD COLUMN IF NOT EXISTS gear        text;     -- bike or shoes, by name
CREATE INDEX IF NOT EXISTS activity_ended_at ON activity (ended_at);
