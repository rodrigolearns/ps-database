-- Create basic schemas for PaperStacks

-- Profiles schema
CREATE TABLE public.profiles (
  id UUID REFERENCES auth.users NOT NULL PRIMARY KEY,
  updated_at TIMESTAMP WITH TIME ZONE,
  username TEXT UNIQUE,
  full_name TEXT,
  avatar_url TEXT,
  website TEXT,
  bio TEXT,
  
  CONSTRAINT username_length CHECK (char_length(username) >= 3)
);

-- Papers schema
CREATE TABLE public.papers (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  title TEXT NOT NULL,
  _abstract TEXT,
  authors TEXT[] NOT NULL,
  user_id UUID REFERENCES public.profiles(id) NOT NULL,
  pdf_url TEXT,
  status TEXT DEFAULT 'draft'
);

-- Reviews schema
CREATE TABLE public.reviews (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  paper_id UUID REFERENCES public.papers(id) NOT NULL,
  reviewer_id UUID REFERENCES public.profiles(id) NOT NULL,
  content TEXT NOT NULL,
  rating INTEGER CHECK (rating >= 1 AND rating <= 5),
  status TEXT DEFAULT 'pending'
);

-- Reviewer Team schema
CREATE TABLE public.reviewer_teams (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  paper_id UUID REFERENCES public.papers(id) NOT NULL,
  user_id UUID REFERENCES public.profiles(id) NOT NULL,
  role TEXT NOT NULL,
  joined_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  UNIQUE (paper_id, user_id)
);

-- Enable RLS
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.papers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reviewer_teams ENABLE ROW LEVEL SECURITY;

-- Create policies
CREATE POLICY "Public profiles are viewable by everyone."
  ON public.profiles FOR SELECT
  USING (true);

CREATE POLICY "Users can insert their own profile."
  ON public.profiles FOR INSERT
  WITH CHECK (auth.uid() = id);

CREATE POLICY "Users can update own profile."
  ON public.profiles FOR UPDATE
  USING (auth.uid() = id);

-- Setup storage
INSERT INTO storage.buckets (id, name) VALUES ('papers', 'papers');
CREATE POLICY "Paper PDFs are accessible to authenticated users"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'papers' AND auth.role() = 'authenticated');

CREATE POLICY "Users can upload paper PDFs"
  ON storage.objects FOR INSERT
  WITH CHECK (bucket_id = 'papers' AND auth.role() = 'authenticated');

-- Create functions
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name, avatar_url)
  VALUES (new.id, new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'avatar_url');
  RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE PROCEDURE public.handle_new_user(); 