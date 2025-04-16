# PaperStacks Database Schema

This document outlines the database schema for the PaperStacks platform.

## Tables

### profiles
Stores user profile information linked to Supabase Auth.

| Column | Type | Description |
|--------|------|-------------|
| id | UUID | Primary key, references auth.users |
| updated_at | TIMESTAMP | Last update timestamp |
| username | TEXT | Unique username |
| full_name | TEXT | User's full name |
| avatar_url | TEXT | URL to user's avatar |
| website | TEXT | User's personal website |
| bio | TEXT | User biography |

### papers
Stores academic papers submitted to the platform.

| Column | Type | Description |
|--------|------|-------------|
| id | UUID | Primary key |
| created_at | TIMESTAMP | Creation timestamp |
| updated_at | TIMESTAMP | Last update timestamp |
| title | TEXT | Paper title |
| _abstract | TEXT | Paper abstract |
| authors | TEXT[] | Array of author names |
| user_id | UUID | References profiles.id |
| pdf_url | TEXT | URL to stored PDF |
| status | TEXT | Paper status (draft, published, etc.) |

### reviews
Stores reviews submitted for papers.

| Column | Type | Description |
|--------|------|-------------|
| id | UUID | Primary key |
| created_at | TIMESTAMP | Creation timestamp |
| updated_at | TIMESTAMP | Last update timestamp |
| paper_id | UUID | References papers.id |
| reviewer_id | UUID | References profiles.id |
| content | TEXT | Review content |
| rating | INTEGER | Rating (1-5) |
| status | TEXT | Review status |

### reviewer_teams
Maps reviewers to papers they are reviewing.

| Column | Type | Description |
|--------|------|-------------|
| id | UUID | Primary key |
| paper_id | UUID | References papers.id |
| user_id | UUID | References profiles.id |
| role | TEXT | Role in the team |
| joined_at | TIMESTAMP | When user joined the team |

## Relationships

```
profiles 1 --- * papers (User submits many papers)
papers 1 --- * reviewer_teams (Paper has many reviewers)
profiles 1 --- * reviewer_teams (User can review many papers)
papers 1 --- * reviews (Paper receives many reviews)
profiles 1 --- * reviews (User writes many reviews)
```

## Row Level Security Policies

The database uses Supabase RLS policies to secure data access:

- Public profiles are viewable by everyone
- Users can only update their own profile
- Papers are viewable by authenticated users
- Paper owners can edit their own papers
- Reviews are viewable by paper owners and reviewers
- Reviewers can only edit their own reviews 