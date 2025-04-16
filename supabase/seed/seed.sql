-- Seed data for development environment

-- Insert test users
-- Note: In a real setup, you'd use auth.users but for development seeds we're inserting directly
INSERT INTO public.profiles (id, username, full_name, avatar_url, bio)
VALUES 
  ('00000000-0000-0000-0000-000000000001', 'johndoe', 'John Doe', 'https://i.pravatar.cc/150?u=johndoe', 'Research scientist focusing on ML applications'),
  ('00000000-0000-0000-0000-000000000002', 'janesmith', 'Jane Smith', 'https://i.pravatar.cc/150?u=janesmith', 'Professor of Computer Science at MIT'),
  ('00000000-0000-0000-0000-000000000003', 'mikebrown', 'Mike Brown', 'https://i.pravatar.cc/150?u=mikebrown', 'PhD student researching quantum computing');

-- Insert test papers
INSERT INTO public.papers (id, title, _abstract, authors, user_id, status)
VALUES
  (
    '00000000-0000-0000-0000-000000000101',
    'The Effects of Machine Learning on Scientific Research',
    'This paper explores the transformative impact of machine learning algorithms on scientific research methodologies.',
    ARRAY['John Doe', 'Jane Smith'],
    '00000000-0000-0000-0000-000000000001',
    'published'
  ),
  (
    '00000000-0000-0000-0000-000000000102',
    'Quantum Computing: Present and Future Applications',
    'We review the current state of quantum computing technology and explore potential future applications across various industries.',
    ARRAY['Jane Smith', 'Mike Brown'],
    '00000000-0000-0000-0000-000000000002',
    'published'
  ),
  (
    '00000000-0000-0000-0000-000000000103',
    'Climate Change: Analysis of Global Temperature Variations',
    'This study analyzes temperature data from the past century to identify patterns in global climate change.',
    ARRAY['Mike Brown', 'John Doe'],
    '00000000-0000-0000-0000-000000000003',
    'draft'
  );

-- Insert reviewer teams
INSERT INTO public.reviewer_teams (paper_id, user_id, role)
VALUES
  ('00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000002', 'reviewer'),
  ('00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000003', 'reviewer'),
  ('00000000-0000-0000-0000-000000000102', '00000000-0000-0000-0000-000000000001', 'reviewer');

-- Insert sample reviews
INSERT INTO public.reviews (paper_id, reviewer_id, content, rating, status)
VALUES
  (
    '00000000-0000-0000-0000-000000000101',
    '00000000-0000-0000-0000-000000000002',
    'This paper provides an excellent overview of the topic with strong methodology.',
    5,
    'completed'
  ),
  (
    '00000000-0000-0000-0000-000000000102',
    '00000000-0000-0000-0000-000000000001',
    'The paper has good potential but would benefit from more detailed explanations of the quantum algorithms.',
    4,
    'completed'
  ); 